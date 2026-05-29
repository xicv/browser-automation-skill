# Phase 15 — Webwright delegated agent-loop verb (`browser-delegate`)

Status: DRAFT (design only — no code lands from this doc). Author decision pending review.
Date: 2026-05-29. Supersedes nothing. Companion to `references/midscene-integration.md` (sister "delegated loop" backend).

## 1. Motivation — validated by Tier A

A Tier A standalone validation (2026-05-29) ran microsoft/Webwright (MIT) driven by **GLM-5.1** via its Anthropic-compatible endpoint (`https://api.z.ai/api/anthropic/v1/messages`). Result on a 3-item Hacker News scrape:

| Metric | Value |
|---|---|
| Steps | 13 |
| GLM tokens (cumulative) | 53,658 (47,338 in + 6,320 out) + 359,616 cached |
| Billed to | the **GLM key**, not Claude Code |
| Claude Code context cost | ~1 dispatch command + ~6-line result (hundreds of tokens) |
| Auth | `x-api-key` accepted by Z.AI (no 401) |
| Key in artifacts | `<redacted>` by Webwright |

The thesis holds: a self-contained agent loop driven by a cheap secondary LLM moves the entire observe-execute-inspect token cost OFF Claude Code's context and onto a separate (cheaper) provider budget. This spec designs how to fold that capability into the skill WITHOUT compromising our local-credential, token-accounting, or determinism guarantees.

## 2. OSS prior-art survey (delegated-loop class)

Our 4 existing adapters (chrome-devtools-mcp, playwright-cli, playwright-lib, obscura) are all **primitive-verb** adapters: each implements single actions (open/click/fill/snapshot/...) and the agent loop runs IN Claude Code's context — every page state round-trips into Claude tokens.

A second, distinct class is emerging — **delegated agent loops** that close the loop out-of-process with their own model:

| Backend | License | Grounding | Loop model | Persists |
|---|---|---|---|---|
| microsoft/Webwright | MIT | code-as-action (writes Playwright/bash) | own backend (OpenAI/Anthropic/OpenRouter; GLM via Anthropic-compat) | code + logs + screenshots in workspace |
| midscene `aiAct` (auto-planning) | MIT | vision (VLM screenshots) | own VLM (Qwen3-VL / UI-TARS / GPT) | cache yaml |
| browser-use / similar | varies | DOM + vision hybrid | own LLM | varies |

Webwright and midscene-aiAct are the same CLASS: hand them a task, they iterate internally, return a result. They differ on grounding (code vs pixels). Both belong at the orchestration layer of our skill, not the primitive-verb layer. This spec covers Webwright; the midscene path (see `references/midscene-integration.md`) can share the same `browser-delegate` envelope later.

## 3. Architectural decision — higher-order verb, NOT a `lib/tool` adapter

A `lib/tool/<tool>.sh` adapter must implement the fixed 11-function contract (3 identity + 8 primitive verbs: open/click/fill/snapshot/inspect/audit/extract/eval), per `references/recipes/add-a-tool-adapter.md`. Webwright does NOT map onto primitive verbs — it executes whole multi-step TASKS. Forcing it into the adapter contract (returning exit-41 for all 8 primitives, smuggling a task into one of them) would be a category error.

**Decision:** model Webwright as a new higher-order command `scripts/browser-delegate.sh`, peer to the existing orchestration verbs `browser-flow.sh` / `browser-do.sh` / `browser-replay.sh` — NOT a router-dispatched primitive adapter. Rationale:

- Primitive adapters implement single actions; `browser-delegate` orchestrates an external task loop.
- It runs out-of-process with its own model — the router's per-verb adapter-selection logic does not apply.
- It composes with the skill at the orchestration layer (credential bridge, telemetry, replay), the same layer `browser-flow`/`browser-do` already occupy.

Anti-pattern AP-3/AP-4 still apply in spirit: `browser-delegate` is **opt-in by explicit invocation**, never auto-selected, and is introduced "ship dark" before any promotion.

## 4. Component design — `scripts/browser-delegate.sh`

Inputs:
- `--task <text>` or task via stdin (long tasks).
- `--start-url <url>` (required).
- `--site <name>` (optional — resolves stored session for the credential bridge, §5).
- `--task-id <id>` (output folder name; default derived).
- `--max-steps <n>` (cap; surfaced as Webwright budget).
- `--backend webwright` (default and only backend in phase 1).
- `--dry-run` (print the resolved Webwright command + config, spawn nothing).

Behavior:
1. Locate the Webwright install via `BROWSER_SKILL_WEBWRIGHT_DIR` (default `$HOME/tools/Webwright`); fail with an install hint if absent (advisory, like the midscene llama-server check — see §13).
2. Resolve output dir to `$HOME/.browser-skill/delegate/<task-id>` (mode 0700) — NOT Webwright's repo `outputs/` (§6).
3. Shell to `python -m webwright.run.cli -c base.yaml -c model_claude.yaml -t <task> --start-url <url> --task-id <id> -o <secure-out>` inside the Webwright venv.
4. On completion, parse `<secure-out>/<run>/trajectory.json` → `model.usage.cumulative_response` for token + step counts.
5. Run the privacy-canary scan (§6) over the trajectory BEFORE returning anything.
6. Emit a single compact summary via `emit_summary` (TOON/token-efficient, per `docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md`): `final_response`, workspace path, step count, offloaded-token count, success flag. NEVER dump the full trajectory into stdout (would defeat the token-offload purpose).
7. Emit a stats event (§7).

## 4a. Lifecycle — doctor / setup / cleanup

Webwright is an external install (`$HOME/tools/Webwright` venv + Playwright browsers + a global `.env` holding the GLM key). The skill's `browser-doctor.sh` walks only `lib/tool/*.sh` adapters, so a higher-order verb is invisible to it; `uninstall.sh` only removes the skill symlink. Three lifecycle touchpoints close that gap WITHOUT violating AP-8 (no network at source time) or the midscene "don't bundle big downloads" stance:

- **doctor (INFORM, advisory, never fails):** add a `webwright_delegate` advisory block to `browser-doctor.sh` modeled exactly on the existing Phase-14 `local_vlm` block. Checks: `BROWSER_SKILL_WEBWRIGHT_DIR` (default `$HOME/tools/Webwright`) + `.venv` present; global `.env` present and `ANTHROPIC_API_KEY` non-empty (report present/absent — NEVER print or log the key value); Playwright browsers present. Emits `{check:"webwright_delegate", installed:<bool>, configured:<bool>}`. Never increments `problems`. This is the one place `browser-doctor.sh` learns about a non-adapter backend — justified because doctor is the framework-level health surface; AP-1 forbids adapter-specific checks, but this is a higher-order-verb backend (not one of the 8 primitive verbs), and the check is generic to the delegate verb.
- **setup (DO-IT-FOR-THEM, explicit only):** a `browser-delegate --setup` path performs clone + venv + `pip install -e .` + `playwright install` on EXPLICIT user request. Never auto-run from doctor or `install.sh` (hundreds of MB; AP-8).
- **cleanup (INFORM by default, DELETE opt-in):** extend `uninstall.sh` to report the Webwright footprint (install dir + size, the global `.env` containing the GLM secret, the ms-playwright cache) and add an opt-in `--delete-webwright` flag that removes them. Default stays inform-only — a user secret and a hundreds-MB tool must never vanish silently.

## 5. Credential / session bridge — security crux

Webwright spawns its OWN Playwright browser with a fresh profile and persists ALL intermediate logs + screenshots. Our credentials live under `$HOME/.browser-skill` (0700 dir / 0600 files), never on argv, never in the transcript.

Phase 1 (this spec): **no-auth tasks only.** `browser-delegate` refuses (exit non-zero) if `--site` resolves to a site requiring stored credentials, with a message pointing here. This avoids leaking secrets into Webwright's plaintext workspace before the bridge exists.

Phase 2 (deferred): bridge our stored `storage_state` (cookies, not raw passwords) into the Webwright run start so a logged-in session is reused WITHOUT typing secrets into a form (which would land in screenshots/logs). Passwords are never handed to Webwright. Secrets that must pass go via stdin only (AP-7). Webwright's own API key already lives off-argv in its global `.env` (good).

## 6. Privacy-canary gate

Webwright workspace = plaintext screenshots + bash logs + raw model responses. Our privacy model forbids that escaping the 0700 sandbox.

- Redirect Webwright `-o` to `$HOME/.browser-skill/delegate/<id>` (0700).
- After the run, scan `trajectory.json` + `raw_responses.jsonl` + `logs/` for known secret patterns using the existing `references/recipes/privacy-canary.md` machinery. If a canary/secret pattern is found, REFUSE to return the result and emit a redaction warning instead.
- Acceptance test seeds a canary string into a fixture trajectory and asserts the gate refuses.

## 7. Telemetry capture — keep the audit honest

The skill's balance-of-tokens/accuracy/latency audit (`stats.jsonl` / `browser-stats`) goes blind on delegated runs unless we capture Webwright's metrics.

- After each run, append a `stats.jsonl` event: `tool=webwright`, `verb=delegate`, `steps=<n>`, `offloaded_input_tokens`, `offloaded_output_tokens`, `cached_input_tokens`, `latency_ms`, `success`.
- NEW field semantics: `offloaded_*` tokens are billed to the secondary (GLM) budget, NOT Claude context. `browser-stats` must report these in a separate column so the audit does not conflate offloaded tokens with Claude-context tokens. This is the single most important reporting change — without it the "savings" story is unmeasurable.

## 8. craft → replay combo (the determinism win)

Webwright is probabilistic; our `browser-replay` / `browser-do` cache is deterministic and 0-token. Pair them:

1. First encounter of a novel multi-step task → `browser-delegate` (expensive once, on GLM).
2. On success, optionally crystallize the run into a parameterized script (Webwright `crafted_cli.yaml` / `/webwright:craft` equivalent) and register it as a replayable flow in our flow system.
3. Subsequent runs → `browser-replay` (deterministic, 0 Claude tokens, 0 GLM tokens).

Webwright for discovery; our cache for repetition.

## 9. Code-execution risk (do not hand-wave)

Webwright runs LLM-generated bash/python on the host. A secondary model (GLM) now writes code we execute. Phase 1 mitigation: run under the user's existing trust boundary, document the risk loudly, and DO NOT auto-promote or auto-route to it. Phase 2: evaluate a restricted shell / container sandbox for the Webwright subprocess. Tracked as an open risk; gates promotion.

## 10. Routing / opt-in posture

`browser-delegate` is invoked explicitly. The router never auto-selects it. Heuristic guidance (docs only): use it for NOVEL multi-step tasks where the primitive-verb loop would push many snapshots into Claude context; do NOT use it for single-step extracts (cached primitive verbs win on both token and latency).

## 11. Model config notes (already set in Tier A)

- `model_claude.yaml`: `model_class: anthropic`, `model_name: glm-5.1`, `anthropic_endpoint: https://api.z.ai/api/anthropic/v1/messages`, `max_output_tokens: 16000` (override of base.yaml 4000 for large extractions).
- Key in Webwright global `.env` (`ANTHROPIC_API_KEY`), 0600, off-argv.
- If Z.AI rejects `x-api-key` on a future model, patch `_request_headers()` in `anthropic_model.py` to `Authorization: Bearer` (not needed for glm-5.1 as of Tier A).

## 12. Acceptance criteria (RED-GREEN bats)

1. `browser-delegate --dry-run --task "x" --start-url https://example.com` prints the resolved Webwright command + secure output path; spawns nothing.
2. A no-auth task returns a compact `emit_summary` (final_response + workspace + steps + offloaded tokens); full trajectory NOT in stdout.
3. `stats.jsonl` gains one `verb=delegate` event with non-zero `offloaded_*` token fields after a real run.
4. Privacy-canary: a seeded canary secret in a fixture trajectory causes `browser-delegate` to REFUSE and warn.
5. `--site` resolving to a credentialed site is REFUSED in phase 1 with a pointer to §5.
6. Claude-context cost of a delegate run is bounded (dispatch + summary) and independent of step count — assert summary byte size ceiling.
7. `browser-doctor` advisory-reports Webwright venv + `.env` presence (ok / warn-not-configured), never hard-fails, and NEVER prints the key value.
8. `uninstall.sh` (default) reports the Webwright footprint + the GLM-secret `.env` location but deletes nothing; `uninstall.sh --delete-webwright` removes the install dir + `.env` + (opt-in) browsers.
9. `browser-delegate --setup` clones + builds Webwright on explicit invocation only; never triggered by `doctor` or `install.sh`.

## 13. What NOT to do

- Don't make `browser-delegate` a router default (AP-3/AP-4) — ship dark, explicit-invoke only.
- Don't run auth/credentialed tasks through Webwright until the §5 bridge exists.
- Don't dump the full trajectory into Claude context — defeats the entire purpose; return a compact summary only.
- Don't bundle Webwright (or Playwright browsers, ~hundreds of MB) into `install.sh`. Advisory `doctor` check only, mirroring the midscene/llama-server stance.
- Don't conflate offloaded (GLM) tokens with Claude-context tokens in `browser-stats`.

## 14. Open questions / phasing

- Phase 1: no-auth `browser-delegate` + stats capture + privacy-canary gate + doctor advisory.
- Phase 2: storage_state credential bridge; sandbox for code-exec; craft→replay registration; optional midscene-aiAct as a second `--backend`.
- Open: should the secure output dir auto-prune old delegate runs (retention like captures)? Should `--max-steps` map to a Webwright budget knob or a wall-clock timeout?

## 15. References

- Tier A measurement + decision: project memory `ref_webwright_eval.md`.
- Webwright: https://github.com/microsoft/Webwright — MS Research article https://www.microsoft.com/en-us/research/articles/webwright-a-terminal-is-all-you-need-for-web-agents/
- GLM Anthropic-compatible endpoint: https://docs.z.ai/scenario-example/develop-tools/claude
- Sister delegated-loop backend: `references/midscene-integration.md`
- Adapter conventions (why this is NOT a lib/tool adapter): `references/recipes/add-a-tool-adapter.md`, `references/recipes/anti-patterns-tool-extension.md`
- Token-efficient output: `docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md`
- Privacy canary: `references/recipes/privacy-canary.md`
