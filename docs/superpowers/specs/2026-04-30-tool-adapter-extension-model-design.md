# Tool Adapter Extension Model — Design Spec

| Field | Value |
|---|---|
| Status | Draft for review |
| Author | xicao |
| Date | 2026-04-30 |
| Spec ID | 2026-04-30-tool-adapter-extension-model-design |
| Augments | `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` (the *parent spec*) — specifically §3.3 (adapter contract) and §13.2 Recipe 2 (add-a-tool-adapter) |
| Successor | This spec → implementation plan via `superpowers:writing-plans` (Phase 3 ships playwright-cli against this contract) |
| Reference skill | `https://github.com/xicv/mqtt-skill` (proven structural template) |

---

## 0. Why this spec exists

The parent spec answers *"how do we drive a browser from Claude Code?"* in 1.2k lines. It locks in a four-tool routing model with a uniform adapter contract (§3.3) and a "five recipes" maintainability story (§13.2). Both are sound, but the parent spec leaves three concrete questions under-specified:

1. **What file do I edit when I add a new tool?** The parent spec lists ~7 steps in Recipe 2 but does not draw the line between "core" and "extension surface." A future contributor adding `puppeteer` cannot answer "do I touch `browser-doctor.sh`?" without reading the recipe alongside the architecture diagram and inferring intent.
2. **How do adapters and the router talk?** The parent spec declares both exist; this spec defines the actual contract — what the adapter exports, what the router asks, and how the two stay in sync.
3. **What can a contributor do without core changes, vs. what requires a routing precedence decision?** This spec introduces the **two-path recipe** (Path A: ship-without-promotion; Path B: promote-to-default) so the answer is procedurally crisp.

The parent spec gets a single `see §3.3-pointer` paragraph; nothing is deleted, nothing is forklift-edited.

### Reading order

This spec is dense but flat. Sections 2–4 are the contract; Sections 5–7 are the surrounding machinery; Section 8 is the dev-facing recipe; Section 9 is the worked-example "don't do this" catalog the parent spec didn't have.

---

## 1. Locked-in decisions

| Decision | Choice | Why |
|---|---|---|
| Extension scope | **First-party only** — adapters live in this repo and ship via PR review. No `BROWSER_SKILL_HOME/tools/<custom>.sh` runtime discovery. | Plugin systems are 10× the maintenance cost for a 1× audience. Parent spec §6.7 leaves a v2 marketplace door open without paying now. |
| Coupling model | **Z hybrid** — adapters self-register doctor checks and capability declarations; routing precedence stays centralized in `lib/router.sh`. | Routing precedence is a **global** decision (when two adapters can both do verb V, who wins?). Localizing precedence in one file beats scattering it across N adapters. Doctor and capabilities are intrinsically per-tool, so they self-register cleanly. |
| Deliverable shape | **New focused spec doc** that augments — not replaces — the parent spec's §3.3 and §13.2. | Parent spec is already at the readable ceiling. The "how do I add a tool?" topic earns first-class billing. |
| ABI versioning | Each adapter declares `abi_version`; framework declares `BROWSER_SKILL_TOOL_ABI`; mismatch is fail-fast at adapter-source time. | Cheap to ship now, expensive to retrofit. Catches silent contract skew. |
| Optional hooks | `tool_pre_capture` / `tool_post_capture` deferred to Phase 4+ (not even reserved in v1). | YAGNI. Add via `[feat]` PR when an adapter actually needs them. |
| Autogeneration policy | **Manual regen + drift-fail in CI**, never auto-rewrite-on-commit. | Keeps every diff intentional; matches the project's "don't commit formatting changes" discipline. |
| Worked example shape | **WRONG / RIGHT code-snippet pairs** for top-six anti-patterns; brief prose for next three. | Highest signal-to-noise for pattern-matching. |

---

## 2. Adapter ABI surface

This is the contract every `scripts/lib/tool/<tool>.sh` implements. Identity functions are queried by the framework (router, doctor, lint, autogen). Verb-dispatch functions are called once per verb invocation, after the router has selected exactly one adapter.

> **See also:** [Token-Efficient Adapter Output design spec](2026-05-01-token-efficient-adapter-output-design.md) governs the bytes a verb-dispatch function emits to stdout/stderr — single-line summary contract, `eN` element refs, capture-paths-not-inline, `--raw` / `--json` / `--depth` flag semantics, and the six WRONG/RIGHT anti-pattern pairs. Adapter authors implement the ABI here and emit through the helpers in `scripts/lib/output.sh` (Phase 3 deliverable). Lint tier 3 (§7 below) enforces output-shape drift.

### 2.1 Required identity & capability functions

```bash
# Returns JSON: identity & ABI version.
# Required keys: name, abi_version, version_pin, cheatsheet_path.
# Called by: router (ABI validation), doctor (aggregation), lint, autogen.
tool_metadata() {
  cat <<'EOF'
{
  "name": "playwright-cli",
  "abi_version": 1,
  "version_pin": "1.49.x",
  "cheatsheet_path": "references/playwright-cli-cheatsheet.md"
}
EOF
}

# Returns JSON: which verbs this adapter supports + (optionally) supported flags.
# Used by the router's capability filter to skip incompatible adapters.
# Verb name absent  → adapter does not support that verb.
# Verb name present → adapter supports it; flags array narrows further (advisory in v1).
tool_capabilities() {
  cat <<'EOF'
{
  "verbs": {
    "open":     { "flags": ["--headed", "--viewport"] },
    "click":    { "flags": ["--ref", "--selector"] },
    "fill":     { "flags": ["--ref", "--text", "--secret-stdin"] },
    "snapshot": {},
    "inspect":  { "flags": ["--selector"] }
  }
}
EOF
}

# Returns JSON: doctor health check. ok/binary/version/install_hint/error.
# MUST NOT exit non-zero — absence of binary is `ok:false` in JSON.
tool_doctor_check() {
  if command -v playwright >/dev/null 2>&1; then
    printf '{"ok":true,"binary":"playwright","version":"%s"}\n' \
      "$(playwright --version 2>/dev/null)"
  else
    cat <<'EOF'
{ "ok": false, "binary": "playwright", "error": "not on PATH",
  "install_hint": "npm i -g playwright @playwright/test && playwright install" }
EOF
  fi
}
```

### 2.2 Required verb-dispatch functions

```bash
tool_open      tool_click    tool_fill      tool_snapshot
tool_inspect   tool_audit    tool_extract   tool_eval
```

Each function:

- Reads its named flags from `"$@"`.
- **Never accepts secrets in argv** — `--secret-stdin` flag means the secret arrives on stdin (already enforced by `tests/argv_leak.bats`).
- Emits zero-or-more streaming JSON lines to stdout, then returns.
- Logs to stderr only.
- Returns 41 (`TOOL_UNSUPPORTED_OP`) if this adapter cannot handle the op or this flag combination. Defensive — the router's capability filter shouldn't have routed here, but the guard is cheap.

### 2.3 What's NOT in the contract (deliberately)

- **`tool_default_routes()`** — adapters declare what they *can* do (`tool_capabilities()`), never what should win when peers also can. Precedence is exclusively a router concern. This is the **Z-hybrid line**.
- **Cross-adapter calls** — adapters are leaves; no peer-to-peer dispatch. Shared logic factors into `scripts/lib/<concern>.sh` (sibling to `lib/tool/`).
- **File I/O outside `BROWSER_SKILL_HOME`** — adapters never read/write outside the session sandbox unless given an explicit path on argv.
- **Reserved hooks** — `tool_pre_capture` / `tool_post_capture` are not part of v1. Adopting them is a `[feat]` change later, not breaking.

### 2.4 ABI evolution rule

Bumping `abi_version` is a `[breaking]` CHANGELOG entry. Bump only when:

1. Adding a **required** function (e.g., promoting `tool_pre_capture` to required).
2. Changing an existing function's signature (positional → flag, JSON shape change).

Adding an **optional** function or **adding fields** to capability JSON is `[feat]` — adapters that don't implement / declare it are fine.

---

## 3. Loading model

Bash's `source` injects functions into the caller's namespace. With multiple adapters all defining `tool_open`, the loading model has to be deliberate.

### 3.1 Two patterns, two strategies

| Pattern | Used by | Strategy |
|---|---|---|
| **Per-verb dispatch** — "pick tool X, run `tool_open`" | `scripts/browser-<verb>.sh` | **Lazy + single source.** Verb script asks router for `TOOL_NAME`, sources exactly **that** `lib/tool/<TOOL_NAME>.sh`, calls `tool_<verb>`, returns. Only one adapter is in scope; no collisions. |
| **Cross-tool aggregation** — "ask every adapter for its doctor / metadata / capabilities" | `browser-doctor.sh`, `tests/lint.sh`, `scripts/regenerate-docs.sh` | **Subshell iteration.** For each `lib/tool/*.sh`, run `( source "$f"; tool_doctor_check )` in a subshell. Each adapter's function definitions live and die in its subshell. |

```bash
# Aggregation example: scripts/browser-doctor.sh
for adapter_file in "${LIB_TOOL_DIR}"/*.sh; do
  adapter_name="$(basename "${adapter_file}" .sh)"
  result="$(
    source "${adapter_file}"
    tool_doctor_check
  )" || result='{"ok":false,"error":"adapter source failed"}'
  jq -c --arg n "${adapter_name}" '. + {check:"adapter",adapter:$n}' <<<"${result}"
done
```

Each subshell is ~3 ms on macOS — well below any sensible budget. The parent shell never sees `tool_open` / `tool_click` / etc.; only the JSON outputs bubble up.

### 3.2 ABI-version validation at source time

When the router sources an adapter for verb dispatch, it validates the ABI **before** calling the verb function:

```bash
# scripts/lib/router.sh after picking TOOL_NAME=playwright-cli
source "${LIB_TOOL_DIR}/${TOOL_NAME}.sh"
declared_abi="$(tool_metadata | jq -r '.abi_version')"
if [ "${declared_abi}" != "${BROWSER_SKILL_TOOL_ABI}" ]; then
  die "${EXIT_PREFLIGHT_FAILED}" \
    "adapter ${TOOL_NAME} declares abi_version=${declared_abi}; framework expects ${BROWSER_SKILL_TOOL_ABI}"
fi
tool_"${verb}" "$@"
```

`BROWSER_SKILL_TOOL_ABI` is a single integer in `lib/common.sh`. Bumping it requires a coordinated PR that bumps every adapter's `abi_version` in lockstep; lint catches stragglers.

### 3.3 What adapters MUST NOT do at file-source time

- No `readonly FOO=...` for variables outside the adapter's namespace prefix (`_BROWSER_TOOL_<UPPERNAME>_*`).
- No network calls, no file writes — sourcing must be cheap and pure.
- No process spawning. `command -v <binary>` is fine; running the binary at source time is not.
- No `cd`. No `umask` change (`common.sh` already sets umask 077).

The lint check (§7) greps adapter files for these patterns and fails CI.

### 3.4 Discovery: filename = adapter name

The router and doctor enumerate `scripts/lib/tool/*.sh` and treat the basename minus `.sh` as the canonical adapter name. The adapter's `tool_metadata().name` MUST match its filename, enforced by lint. This gives:

- A trivial answer to "what adapters exist?" — `ls lib/tool/`.
- A drift check (`name` field vs filename).
- No registry file to keep in sync.

---

## 4. Router precedence + capability filter

This is where the **Z hybrid** earns its name. The router holds an ordered list of precedence rules; capabilities live on adapters; the router consults both.

### 4.1 Two-stage dispatch

```
pick_tool(verb, flags...):
  1. If --tool=X: validate X exists + X.tool_capabilities() supports (verb, flags).
     Hard error if not (USAGE_ERROR — user gave a wrong instruction).
  2. Else: walk ROUTING_RULES top-down.
     For each rule:
        If the rule fires for (verb, flags):
           Ask the named tool's tool_capabilities() — does it support (verb, flags)?
              Yes → dispatch.
              No  → emit debug line, fall through to next rule.
        Otherwise: continue.
  3. Fall-through: die EXIT_TOOL_MISSING with the rule trace.
```

### 4.2 `ROUTING_RULES` as an array of function names

`eval` is in the parent spec's banned-patterns list (§13.4), so each precedence rule is a small bash function. **Adding a new precedence rule = define a function + append to `ROUTING_RULES`.** **Adding a new tool that's NOT a default for any verb = ZERO edits to this file.**

```bash
# scripts/lib/router.sh — the SINGLE precedence table.
ROUTING_RULES=(
  rule_capture_console        # --capture-console        → chrome-devtools-mcp
  rule_capture_network        # --capture-network        → chrome-devtools-mcp
  rule_audit_verb             # verb=audit               → chrome-devtools-mcp
  rule_login_verb             # verb=login               → playwright-lib
  rule_scrape_flag            # --scrape                 → obscura
  rule_stealth_flag           # --stealth                → obscura
  rule_non_chromium           # --firefox / --webkit     → playwright-cli
  rule_default_navigation     # everything else          → playwright-cli
)

rule_capture_console() {
  _has_flag --capture-console "$@" || return 1
  printf 'chrome-devtools-mcp\t--capture-console flag\n'
}
# ... one tiny function per row ...
```

### 4.3 Capability filter (the bridge between router and adapter)

```bash
_tool_supports() {
  local tool="$1" verb="$2"; shift 2
  jq -e --arg v "${verb}" '.verbs | has($v)' >/dev/null <<<"$(
    source "${LIB_TOOL_DIR}/${tool}.sh"
    tool_capabilities
  )"
}
```

This closes the loop with §3.1: the router never **assumes** chrome-devtools-mcp can handle `audit` — it asks. If the adapter is renamed, lint catches it; if it temporarily can't do `audit` (e.g., upstream removed the API), the router falls through.

### 4.4 The ship-without-promotion pattern

A subtle property of this design: **adding a new adapter that's never the default for any verb requires zero edits to `router.sh`.** The tool is reachable via `--tool=X` but won't be picked unless explicitly named. This unlocks a phased-rollout pattern:

1. **Path A (PR #1):** ship `lib/tool/puppeteer.sh` + tests + doctor + cheatsheet. Reachable via `--tool=puppeteer`. **Zero edits to .sh files in `scripts/lib/`.** Soak test in real workflows.
2. **Path B (PR #2, optional, follow-up):** edit `router.sh` to make puppeteer the default for some verb. Routing-rule change with its own review.

This is the pattern §8 (the recipe) endorses explicitly.

### 4.5 Drift detection

| Watch | Test file | Catches |
|---|---|---|
| Routing-doc drift (already in parent spec §13.5) | `tests/routing-doc-sync.bats` | router.sh table ↔ `references/routing-heuristics.md` |
| **Routing-capability drift (new in this spec)** | `tests/routing-capability-sync.bats` | "rule_audit_verb names chrome-devtools-mcp, but adapter forgot to declare audit" |
| Verb-table drift (parent §13.5) | `tests/verb-table-sync.bats` | scripts on disk ↔ SKILL.md verb table |

### 4.6 Error mapping

| Situation | Exit code | Status |
|---|---|---|
| `--tool=X` but X doesn't exist | `EXIT_USAGE_ERROR` (2) | error |
| `--tool=X` but X doesn't support verb/flags | `EXIT_USAGE_ERROR` (2) | error |
| Router fell through all rules; no adapter supports | `EXIT_TOOL_MISSING` (21) | error |
| Adapter chosen by rule, but its `tool_<verb>` returns 41 | `EXIT_TOOL_UNSUPPORTED_OP` (41) | error |
| Adapter's declared `abi_version` mismatches framework | `EXIT_PREFLIGHT_FAILED` (20) | error |

---

## 5. Doctor as the aggregation surface

`browser-doctor.sh` becomes the canonical example of "core does not know about specific tools." Adding a new adapter requires **zero edits** to `browser-doctor.sh`.

### 5.1 Two layers of checks, two homes

| Core layer (hand-coded in `browser-doctor.sh`) | Adapter layer (`tool_doctor_check()` per adapter) |
|---|---|
| state dir exists & mode 0700 | binary on PATH? |
| `~/.browser-skill/version` present | version compatible with `version_pin`? |
| `jq`, `bash` ≥ 4 (or compatible) | adapter-specific deps (browsers installed, MCP server reachable) |
| disk encryption (FileVault / LUKS) | install hint on failure |
| repo credential sweep (no `.env` in worktree) | |
| no-network self-test | |

**Core layer** = framework concerns that exist independently of any adapter. **Adapter layer** = anything intrinsic to a single tool.

### 5.2 Walk pattern (zero core edits per new tool)

```bash
# scripts/browser-doctor.sh — the adapter loop is invariant
adapters_ok=0; adapters_failed=0
for adapter_file in "${LIB_TOOL_DIR}"/*.sh; do
  adapter_name="$(basename "${adapter_file}" .sh)"
  result="$(
    source "${adapter_file}"
    tool_doctor_check
  )" || result='{"ok":false,"error":"adapter source failed"}'

  jq -c --arg n "${adapter_name}" '. + {check:"adapter",adapter:$n}' <<<"${result}"

  if [ "$(jq -r .ok <<<"${result}")" = "true" ]; then
    adapters_ok=$((adapters_ok+1))
  else
    adapters_failed=$((adapters_failed+1))
  fi
done
```

### 5.3 Status semantics

| Situation | `status` | Exit code |
|---|---|---|
| All adapters ok + all core checks pass | `ok` | 0 |
| Some adapters ok, some not | `partial` | 0 (informational; individual verbs surface their own errors when invoked) |
| No adapters ok | `error` | `EXIT_PREFLIGHT_FAILED` (20) |
| Core check failed (mode 0700 wrong, jq missing) | `error` | code-appropriate |

### 5.4 Concrete win for Phase 3

The Phase-3 kickoff brief notes:

> "Update `scripts/browser-doctor.sh` to elevate `node` from advisory to required; add `playwright-cli` and `playwright browsers` checks."

With this design, **only** the framework-level change (`node` advisory → required) lives in `browser-doctor.sh`. The `playwright-cli` and `playwright browsers` checks live entirely in `lib/tool/playwright-cli.sh::tool_doctor_check()`. When obscura ships in Phase 8, its doctor checks similarly land in `lib/tool/obscura.sh` — no second edit to `browser-doctor.sh`.

---

## 6. Autogeneration of cross-cutting docs

Manual-regen + drift-fail in CI, never auto-rewrite-on-commit. Matches the project's "don't commit formatting changes" discipline.

### 6.1 What gets autogenerated, from what

| Generated file | Source of truth | Contents |
|---|---|---|
| `references/tool-versions.md` | each adapter's `tool_metadata()` + `tool_doctor_check()` | Version-pin table: name, version_pin, install_hint, cheatsheet path |
| `## Tools` section of `SKILL.md` (between markers) | each adapter's `tool_metadata()` | LLM-facing one-liner per tool: name, "what it does," cheatsheet link |

What stays **hand-written**:

| File | Why hand-written |
|---|---|
| `references/<tool>-cheatsheet.md` | Content; can't be derived from JSON |
| `references/routing-heuristics.md` | The "why" of each routing rule is contextual prose; drift-tested |
| Everything outside marker blocks in `SKILL.md` | Verbs table, install instructions, output contract |

### 6.2 The generator script

```bash
# scripts/regenerate-docs.sh — invoked by hand; never by hooks.
regenerate_tool_versions() {
  {
    printf '# Tool versions (autogenerated — do not edit; run scripts/regenerate-docs.sh)\n\n'
    printf '| Tool | Version pin | Install hint | Cheatsheet |\n'
    printf '|---|---|---|---|\n'
    for adapter_file in "${LIB_TOOL_DIR}"/*.sh; do
      meta="$(source "${adapter_file}"; tool_metadata)"
      doctor="$(source "${adapter_file}"; tool_doctor_check)"
      jq -r --argjson meta "${meta}" --argjson doctor "${doctor}" '
        "| \($meta.name) | \($meta.version_pin) | \($doctor.install_hint // "n/a") | [\($meta.cheatsheet_path)](../\($meta.cheatsheet_path)) |"
      ' <<<'null'
    done
  } > references/tool-versions.md
}

regenerate_skill_md_tools_section() {
  # Replaces content between `<!-- BEGIN AUTOGEN: tools-table -->`
  # and `<!-- END AUTOGEN: tools-table -->` markers in SKILL.md.
  # Outside-marker content is preserved verbatim.
  # ... awk-based marker replacement, writes back to SKILL.md ...
}
```

### 6.3 The drift-fail lint check

```bash
# tests/lint.sh appendix
ensure_docs_in_sync() {
  local tmp_versions tmp_skill
  tmp_versions="$(mktemp)"; tmp_skill="$(mktemp)"
  scripts/regenerate-docs.sh --to-stdout tool-versions > "${tmp_versions}"
  scripts/regenerate-docs.sh --to-stdout skill-md     > "${tmp_skill}"

  diff -u references/tool-versions.md "${tmp_versions}" \
    || { echo "tool-versions.md is stale; run scripts/regenerate-docs.sh"; exit 1; }
  diff -u <(extract_skill_md_tools_section SKILL.md) "${tmp_skill}" \
    || { echo "SKILL.md tools section is stale; run scripts/regenerate-docs.sh"; exit 1; }
}
```

Dev workflow: edit your adapter → run `tests/run.sh` → see drift fail → run `scripts/regenerate-docs.sh` → commit. **Nothing rewrites your files behind your back.** Generator output is content-stable (sorted by adapter name) — reproducible across machines.

### 6.4 The `## Tools` marker block in `SKILL.md`

```markdown
## Tools

The skill routes verbs to one of these underlying tools (see
[routing heuristics](references/routing-heuristics.md) for the precedence rules):

<!-- BEGIN AUTOGEN: tools-table — generated by scripts/regenerate-docs.sh -->
| Tool | Strengths | Cheatsheet |
|---|---|---|
| playwright-cli | Default for navigation; cheap, multi-browser | [playwright-cli-cheatsheet.md](references/playwright-cli-cheatsheet.md) |
| playwright-lib | login (storageState capture); multi-step flows | [playwright-lib-cheatsheet.md](references/playwright-lib-cheatsheet.md) |
| chrome-devtools-mcp | Console + network capture; lighthouse audit | [chrome-devtools-mcp-tools.md](references/chrome-devtools-mcp-tools.md) |
| obscura | Stealth + parallel scrape | [obscura-cheatsheet.md](references/obscura-cheatsheet.md) |
<!-- END AUTOGEN: tools-table -->
```

---

## 7. Lint enforcement

Three tiers; everything mandatory (CI-failing) per parent spec §13.4's "warnings fail" stance.

### 7.1 Static checks (file-content)

```bash
REQUIRED_ADAPTER_FUNCTIONS=(
  tool_metadata tool_capabilities tool_doctor_check
  tool_open tool_click tool_fill tool_snapshot
  tool_inspect tool_audit tool_extract tool_eval
)

lint_adapter_static() {
  local f="$1" name errors=0
  name="$(basename "${f}" .sh)"

  for fn in "${REQUIRED_ADAPTER_FUNCTIONS[@]}"; do
    grep -qE "^(function +)?${fn}\s*\(\)" "${f}" \
      || { warn "lint: ${f}: missing required function ${fn}"; errors=$((errors+1)); }
  done

  # Banned at file-source scope (must be inside a tool_* function).
  if grep -nE '^[^#]*\b(curl|wget|nc)\b' "${f}" \
       | grep -v 'tool_doctor_check\|tool_open\|tool_inspect'; then
    warn "lint: ${f}: network call at file scope"
    errors=$((errors+1))
  fi
  if grep -nE '^[^#]*\bcd\b' "${f}"; then
    warn "lint: ${f}: cd at file scope is forbidden"; errors=$((errors+1))
  fi

  # Each adapter MUST have a corresponding *_adapter.bats test file.
  [ -f "${REPO_ROOT}/tests/${name}_adapter.bats" ] \
    || { warn "lint: ${f}: missing tests/${name}_adapter.bats"; errors=$((errors+1)); }

  return "${errors}"
}
```

### 7.2 Dynamic checks (subshell + JSON validation)

```bash
lint_adapter_dynamic() {
  local f="$1" name="$(basename "$1" .sh)" errors=0
  local meta
  meta="$(source "${f}"; tool_metadata 2>/dev/null)" \
    || { warn "lint: ${f}: tool_metadata exited non-zero"; return 1; }

  jq -e '.name and .abi_version and .version_pin and .cheatsheet_path' >/dev/null <<<"${meta}" \
    || { warn "lint: ${f}: tool_metadata missing required keys"; errors=$((errors+1)); }

  [ "$(jq -r .name <<<"${meta}")" = "${name}" ] \
    || { warn "lint: ${f}: tool_metadata.name doesn't match filename"; errors=$((errors+1)); }

  [ "$(jq -r .abi_version <<<"${meta}")" = "${BROWSER_SKILL_TOOL_ABI}" ] \
    || { warn "lint: ${f}: abi_version mismatch (framework expects ${BROWSER_SKILL_TOOL_ABI})"; errors=$((errors+1)); }

  local sheet="$(jq -r .cheatsheet_path <<<"${meta}")"
  [ -f "${REPO_ROOT}/${sheet}" ] \
    || { warn "lint: ${f}: cheatsheet ${sheet} doesn't exist"; errors=$((errors+1)); }

  source "${f}"
  jq -e . >/dev/null <<<"$(tool_capabilities)" \
    || { warn "lint: ${f}: tool_capabilities not valid JSON"; errors=$((errors+1)); }
  jq -e . >/dev/null <<<"$(tool_doctor_check)" \
    || { warn "lint: ${f}: tool_doctor_check not valid JSON"; errors=$((errors+1)); }

  return "${errors}"
}
```

Each adapter is checked in **its own subshell** to keep `tool_open` / `tool_click` definitions scoped.

### 7.3 Drift checks

| Check | Where | Catches |
|---|---|---|
| Capability ↔ routing | `tests/routing-capability-sync.bats` | "rule says X wins for V, but X doesn't declare V" |
| `references/tool-versions.md` drift | `tests/lint.sh::ensure_docs_in_sync` | Committed file ≠ generator output |
| `SKILL.md` Tools section drift | `tests/lint.sh::ensure_docs_in_sync` | Marker block stale |
| ABI uniformity | `tests/lint.sh::lint_adapter_dynamic` | One adapter's `abi_version` skewed |

### 7.4 What lint does NOT enforce

- **Sentinel guards** (`_BROWSER_TOOL_<NAME>_LOADED=1`). The loading model only sources each adapter once per shell, so guards are belt-and-suspenders. Recipe recommends; lint doesn't fail.
- **Function complexity** (cyclomatic, deep nesting). The 500-LOC ceiling is a coarse-but-effective signal.
- **Behavioral lint of verb functions.** Declaration-presence is enough for v1. Add when ≥2 adapters disagree on flag support and silent fall-through becomes a real bug.

---

## 8. Recipe — `references/recipes/add-a-tool-adapter.md`

The recipe is the dev-facing checklist that operationalizes Sections 2–7. Below is the **structure**; the full prose lands in the recipe doc itself (≤200 LOC, under the 250-LOC soft cap for `references/*.md`).

### 8.1 Two paths, not one

```markdown
## Path A: Ship-without-promotion (zero edits to existing .sh files)
The adapter is reachable via `--tool=<name>` but never the default for any verb.
This is the recommended way to introduce ANY new tool. Soak-test first, promote later.

## Path B: Promote to default (Path A + one rule in router.sh)
Run only AFTER Path A has shipped and been validated.
```

### 8.2 Path A checklist (all additions; no edits)

1. Create `scripts/lib/tool/<tool>.sh` — implement identity functions (3) and verb-dispatch functions (8). Return 41 for unsupported.
2. Create `tests/stubs/<tool>` — mock binary; logs argv to a file.
3. Create `tests/fixtures/<tool>/` — JSON responses keyed by argv hash.
4. Create `tests/<tool>_adapter.bats` — contract conformance + happy-path tests.
5. Create `references/<tool>-cheatsheet.md` — usage notes.
6. Run `scripts/regenerate-docs.sh` — autogen updates `references/tool-versions.md` and the marker block in `SKILL.md`.
7. Add CHANGELOG entry: `[adapter] added <tool> (Path A — opt-in via --tool=<tool>)`.
8. Run `tests/run.sh` — must be green.

### 8.3 Path B checklist (only after Path A ships)

1. Edit `scripts/lib/router.sh` — add a `rule_<trigger>` function and append it to `ROUTING_RULES`.
2. Update `references/routing-heuristics.md` — add a row matching the rule.
3. Update `tests/router.bats` — one positive + one negative case for the new rule.
4. Add CHANGELOG entry: `[adapter] promoted <tool> to default for <trigger>`.

### 8.4 File-by-file: what every contributor sees

| File | Path A action | Path B action |
|---|---|---|
| `scripts/lib/tool/<tool>.sh` | **CREATE** | (untouched) |
| `tests/stubs/<tool>` | **CREATE** | (untouched) |
| `tests/fixtures/<tool>/` | **CREATE** | (untouched) |
| `tests/<tool>_adapter.bats` | **CREATE** | (untouched) |
| `references/<tool>-cheatsheet.md` | **CREATE** | (untouched) |
| `scripts/lib/router.sh` | (untouched) | **EDIT** (one fn + one array append) |
| `scripts/lib/common.sh` | (untouched) | (untouched) |
| `scripts/browser-doctor.sh` | (untouched) | (untouched) |
| `scripts/browser-<verb>.sh` | (untouched) | (untouched) |
| `references/tool-versions.md` | **AUTOGEN** | (autogen — typically no change) |
| `SKILL.md` | **AUTOGEN** (between markers) | (untouched) |
| `references/routing-heuristics.md` | (untouched) | **EDIT** (one row) |
| `tests/router.bats` | (untouched) | **EDIT** (positive + negative) |
| `CHANGELOG.md` | **EDIT** (one line) | **EDIT** (one line) |

The concrete answer to "what file do we need to change?" is now a single table. **Path A is 5 creates + 2 autogen + 1 changelog line, with zero edits to .sh files in core.** Path B adds one rule function + one array append + one doc row + two tests.

### 8.5 Worked example block

The recipe ships with a runnable walkthrough — "Adding `puppeteer-via-bridge` in 30 minutes" — that scaffolds via `cp scripts/lib/tool/playwright-cli.sh scripts/lib/tool/puppeteer.sh && ...` and validates each step with a one-line test command.

---

## 9. Anti-patterns — `references/recipes/anti-patterns-tool-extension.md`

Six top-priority anti-patterns with WRONG / RIGHT code-snippet pairs; three more brief.

### AP-1: Don't add adapter-specific checks to `browser-doctor.sh`

```bash
# ❌ WRONG — editing core to teach it about a new tool
# scripts/browser-doctor.sh
if ! command -v puppeteer >/dev/null 2>&1; then
  warn "puppeteer not on PATH"
  problems=$((problems+1))
fi
```

```bash
# ✅ RIGHT — adapter declares its own check; doctor aggregates
# scripts/lib/tool/puppeteer.sh
tool_doctor_check() {
  if command -v puppeteer >/dev/null 2>&1; then
    printf '{"ok":true,"binary":"puppeteer","version":"%s"}\n' "$(puppeteer --version)"
  else
    cat <<'EOF'
{ "ok": false, "binary": "puppeteer", "error": "not on PATH",
  "install_hint": "npm i -g puppeteer" }
EOF
  fi
}
```

**SOLID:** SRP — `browser-doctor.sh` knows about framework-level state; `lib/tool/<tool>.sh` knows about its own binary. OCP — adding `puppeteer.sh` should never force an edit to a file in `scripts/` outside `lib/tool/`.

### AP-2: Don't cross-call between adapters

```bash
# ❌ WRONG — adapter reaching into another adapter
# scripts/lib/tool/obscura.sh
tool_inspect() {
  source "${LIB_TOOL_DIR}/playwright-cli.sh"
  tool_inspect "$@"
}
```

```bash
# ✅ RIGHT — shared logic factors into a helper module
# scripts/lib/inspect_helpers.sh   (NEW shared lib — sibling to lib/tool/)
inspect_collect_console() { ... }

# Both adapters source the helper; neither sources the other.
# scripts/lib/tool/obscura.sh
source "${BROWSER_SKILL_LIB}/inspect_helpers.sh"
tool_inspect() { inspect_collect_console "$@"; ... }
```

**SOLID:** SRP + DIP — adapters are leaves. If two adapters need the same behavior, that behavior is a *shared concern* and lives in `scripts/lib/` (sibling to `lib/tool/`). Without this rule, the dependency graph stops being a tree.

### AP-3: Don't declare routing precedence in an adapter (the Z-hybrid line)

```bash
# ❌ WRONG — adapter trying to claim "I'm the default for verb=audit"
# scripts/lib/tool/puppeteer.sh
tool_default_routes() {
  cat <<'EOF'
{ "audit": { "priority": 100 } }
EOF
}
```

```bash
# ✅ RIGHT — adapter declares only what it CAN do; router decides who WINS
# scripts/lib/tool/puppeteer.sh
tool_capabilities() {
  cat <<'EOF'
{ "verbs": { "audit": { "flags": ["--lighthouse"] } } }
EOF
}

# scripts/lib/router.sh   (one rule, one place — Path B in the recipe)
rule_audit_verb() {
  [ "${verb:-}" = "audit" ] || return 1
  printf 'puppeteer\taudit verb (Path B promotion)\n'
}
```

**Why:** OCP-fundamentalism would say "let the adapter declare priority and avoid editing the router." But routing precedence among peers is a **global** decision — when puppeteer and chrome-devtools-mcp both claim audit, *somebody* has to break the tie, and centralizing that choice in `router.sh` lets a reviewer see the conflict in one diff.

### AP-4: Don't make a tool default in the same PR that adds it

```diff
# ❌ WRONG — single PR introduces tool AND promotes it
+ scripts/lib/tool/puppeteer.sh           (NEW)
+ tests/puppeteer_adapter.bats            (NEW)
+ tests/stubs/puppeteer                   (NEW)
+ tests/fixtures/puppeteer/               (NEW)
+ references/puppeteer-cheatsheet.md      (NEW)
~ scripts/lib/router.sh                   (EDIT — adds rule_audit_verb → puppeteer)
~ tests/router.bats                       (EDIT)
~ references/routing-heuristics.md        (EDIT)
~ CHANGELOG.md                            (EDIT)
```

```diff
# ✅ RIGHT — two PRs, separated by a soak window
# PR #1 (Path A — ship dark, opt-in via --tool=puppeteer):
+ scripts/lib/tool/puppeteer.sh           (NEW)
+ tests/puppeteer_adapter.bats            (NEW)
+ tests/stubs/puppeteer                   (NEW)
+ tests/fixtures/puppeteer/               (NEW)
+ references/puppeteer-cheatsheet.md      (NEW)
~ CHANGELOG.md                            (EDIT — [adapter] added, opt-in)

# (one week later, after using --tool=puppeteer in real workflows)
# PR #2 (Path B — promote to default):
~ scripts/lib/router.sh                   (EDIT)
~ tests/router.bats                       (EDIT)
~ references/routing-heuristics.md        (EDIT)
~ CHANGELOG.md                            (EDIT — [adapter] promoted)
```

**Why:** Process. A smaller PR is easier to revert. The "ship dark, then promote" pattern is the same hygiene any production system uses for feature flags.

### AP-5: Don't hand-edit autogenerated files

```bash
# ❌ WRONG — manually adding a row to references/tool-versions.md
$ vim references/tool-versions.md   # adds a "puppeteer" row by hand
$ git add references/tool-versions.md && git commit
# tests/lint.sh::ensure_docs_in_sync will fail in CI:
# "tool-versions.md is stale; run scripts/regenerate-docs.sh"
```

```bash
# ✅ RIGHT — let the generator do it; commit the generator's output
$ vim scripts/lib/tool/puppeteer.sh   # implement tool_metadata + tool_doctor_check
$ scripts/regenerate-docs.sh          # autogen edits the marked sections
$ git add scripts/lib/tool/puppeteer.sh references/tool-versions.md SKILL.md
$ git commit
```

**SOLID:** DRY + drift-prevention. The adapter's `tool_metadata()` is the single source of truth; any hand-edit to a generated file creates a second source that will go stale.

### AP-6: Don't pollute the parent-shell namespace from adapter file scope

```bash
# ❌ WRONG — readonly globals at adapter file scope without a namespace prefix
# scripts/lib/tool/puppeteer.sh
readonly TIMEOUT=30
readonly DEFAULT_VIEWPORT='1280x800'
# ... tool_open uses $TIMEOUT
```

```bash
# ✅ RIGHT — namespace the adapter's globals so they cannot collide
# scripts/lib/tool/puppeteer.sh
readonly _BROWSER_TOOL_PUPPETEER_TIMEOUT=30
readonly _BROWSER_TOOL_PUPPETEER_DEFAULT_VIEWPORT='1280x800'
# ... tool_open uses $_BROWSER_TOOL_PUPPETEER_TIMEOUT
```

**Why:** Encapsulation. The current loading model only sources one adapter per parent shell, so collision is unlikely today — but a future verb that consults two adapters in the same shell would clobber `TIMEOUT`. Prefix-namespacing makes globals private without ceremony.

### Three more anti-patterns the recipe doc captures briefly

- **AP-7:** Don't accept secrets in argv — `--secret-stdin` only. (Already a v1 invariant; lint enforces.)
- **AP-8:** Don't run network calls at adapter file-source time. Sourcing must be cheap and pure (§3.3).
- **AP-9:** Don't test only the happy path — every adapter test must cover (a) declaration-presence, (b) capability-JSON validity, (c) unsupported-op exit-41 path, (d) at least one happy path.

---

## 10. Acceptance criteria

A reviewer can declare this design "implemented" when:

1. **Phase 3 ships** `scripts/lib/tool/playwright-cli.sh` implementing the §2 contract (8 verb fns + 3 identity fns + abi_version=1). All required functions present; lint green.
2. **`scripts/lib/router.sh`** uses the `ROUTING_RULES` array-of-function-names pattern from §4.2, with `_tool_supports()` capability filter from §4.3.
3. **`scripts/browser-doctor.sh`** uses the §5.2 walk-pattern for adapter aggregation; only the framework-level `node` check moves from advisory to required as a hand-coded change.
4. **`scripts/regenerate-docs.sh`** exists and is invoked by `tests/lint.sh::ensure_docs_in_sync` to drift-fail when generated artifacts are stale.
5. **`tests/lint.sh`** enforces §7.1 (static), §7.2 (dynamic), §7.3 (drift) — adapter-specific checks become CI-failing.
6. **`references/recipes/add-a-tool-adapter.md`** ships with the §8 two-path checklist + worked-example walkthrough.
7. **`references/recipes/anti-patterns-tool-extension.md`** ships with the §9 six-anti-patterns content.
8. **The parent spec** gets one paragraph in §3.3 pointing at this spec; nothing in the parent is forklift-edited.
9. **`tests/routing-capability-sync.bats`** exists and passes.

When all 9 are true, an outside contributor adding a hypothetical `puppeteer` adapter via Path A can do so by creating exactly 5 files (and editing CHANGELOG.md), with zero edits to any `.sh` file in `scripts/lib/` or `scripts/`.

---

## 11. Out of scope (v1)

| Item | Why deferred |
|---|---|
| Third-party plugin discovery (`BROWSER_SKILL_HOME/tools/<custom>.sh`) | First-party only (decision §1). Door left open via parent spec §6.7. |
| `tool_pre_capture` / `tool_post_capture` hooks | YAGNI; no current adapter needs them. Add via `[feat]` PR when obscura's stealth-fingerprint scrubbing lands in Phase 8. |
| Flag-level capability filtering (currently advisory-only) | Verb-level membership is enough until 3+ adapters disagree on flag support. |
| Behavioral lint of verb functions (e.g., `--help-only` smoke invocation) | Declaration-presence + adapter-bats tests are sufficient for v1. |
| Auto-regeneration of docs on commit (pre-commit hook) | Manual + drift-fail matches "no formatting commits" rule. |
| Capability JSON schema versioning (separate from `abi_version`) | `abi_version` covers both ABI and capability JSON shape; simpler. |
| `references/recipes/remove-a-tool-adapter.md` | Write the first time we deprecate something and have actual experience. |

---

## 12. Open questions / explicit non-decisions

- **Where does `BROWSER_SKILL_TOOL_ABI` get bumped historically?** Track via CHANGELOG `[breaking]` entries and a one-line table at the top of this spec when the time comes. Not a structural concern for v1.
- **Should adapter test files (`tests/<tool>_adapter.bats`) follow a shared template?** Probably yes; defer to the implementation phase to extract the shared parts after playwright-cli's tests are written.
- **Should `references/<tool>-cheatsheet.md` follow a template?** Same answer; emerge by example.

---

## Appendix A — JSON schemas

### A.1 `tool_metadata()` output

```json
{
  "name": "string (required, must match filename basename)",
  "abi_version": "integer (required, must equal BROWSER_SKILL_TOOL_ABI)",
  "version_pin": "string (required; semver-ish or 'any')",
  "cheatsheet_path": "string (required; path relative to repo root)"
}
```

### A.2 `tool_capabilities()` output

```json
{
  "verbs": {
    "<verb-name>": {
      "flags": ["string", ...]
    }
  }
}
```

Verb-name absent → adapter does not support that verb.
`flags` array is advisory in v1 (capability filter checks verb membership only).

### A.3 `tool_doctor_check()` output

```json
{
  "ok": "boolean (required)",
  "binary": "string (required when ok=true)",
  "version": "string (required when ok=true)",
  "error": "string (required when ok=false)",
  "install_hint": "string (required when ok=false)"
}
```

---

## Appendix B — Changes to the parent spec

The parent spec gets exactly one edit: a pointer paragraph appended to §3.3.

```markdown
### 3.3 Tool adapter contract

[existing content stays]

> **See also:** [Tool Adapter Extension Model design spec](2026-04-30-tool-adapter-extension-model-design.md) for the full ABI surface, the loading model, capability-driven routing, autogeneration of cross-cutting docs, lint enforcement, the two-path recipe (Path A: ship-without-promotion; Path B: promote-to-default), and worked anti-pattern examples.
```

No other parent-spec sections are modified. §13.2 Recipe 2 is **augmented** rather than replaced — its 7 high-level steps remain valid; the new spec provides the detail.

---

## Appendix C — Index of new files & artifacts

| File | Created in phase | Purpose |
|---|---|---|
| `scripts/regenerate-docs.sh` | Phase 3 | Manual regen of autogen artifacts |
| `tests/routing-capability-sync.bats` | Phase 3 | Drift check: rules ↔ capabilities |
| `references/recipes/add-a-tool-adapter.md` | Phase 3 | Two-path recipe |
| `references/recipes/anti-patterns-tool-extension.md` | Phase 3 | The "don't do this" catalog |
| `references/tool-versions.md` | Phase 3 (autogen) | Version-pin table |
| New `## Tools` section in `SKILL.md` | Phase 3 (autogen, between markers) | LLM-facing tools summary |
| `BROWSER_SKILL_TOOL_ABI=1` constant in `scripts/lib/common.sh` | Phase 3 | Single integer the framework declares |
