# Phase 9 part 1-iii — `flow record` (codegen wrapper + JS→YAML transformer + password canary)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Third sub-part of Phase 9. Wraps `playwright codegen <site-url>`; captures the emitted JS; transforms to flow YAML; writes to `${BROWSER_SKILL_HOME}/flows/<name>.flow.yaml` (or user-specified `--out`). **Privacy canary on recorder write side** — passwords (detected by accessible-name pattern matching `/password/i`) are replaced with `${secrets.password}` placeholder before persisting.

**Branch:** `phase-09-part-1-iii-flow-record`
**Tag:** `v0.44.0-phase-09-part-1-iii-flow-record`

---

## Recorder lifecycle

```
bash scripts/browser-flow.sh record --site SITE --out FILE [--name NAME]
  → resolves --site (uses storageState if registered)
  → spawns: playwright codegen --target javascript <site-base-url>
  → captures stdout (the JS that codegen emits as user clicks/types)
  → on user closing the headed window, codegen exits → wrapper reads remaining stdout
  → calls flow_record_transform <captured-js> → emits .flow.yaml on stdout
  → writes ${OUT} (mode 0600); chmod
  → emit_summary verb=flow tool=playwright-cli why=record status=ok flow_name out_file step_count password_redactions
```

`--site SITE` optional. If absent, recorder accepts an explicit `--url URL` instead.

`--out FILE` REQUIRED. Default suggested in docs: `${BROWSER_SKILL_HOME}/flows/<name>.flow.yaml`. Per path-security recipe: realpath canonicalize + sensitive-pattern reject.

`--name NAME` optional. Defaults to the basename of `--out` (sans `.flow.yaml`).

## Locked decisions

### F6-a: Transformer scope = regex-based mapper for 6 codegen patterns

```
1. await page.goto('URL')                                     → - open: { url: URL }
2. await page.getByRole('textbox', { name: 'X' }).click()     → - snapshot: {}
                                                                 - click: { ref: ${refs.X} }
3. await page.getByRole('textbox', { name: 'X' }).fill('V')   → - snapshot: {}
                                                                 - fill: { ref: ${refs.X}, text: V }
4. await page.getByRole('button',  { name: 'X' }).click()     → - snapshot: {}
                                                                 - click: { ref: ${refs.X} }
5. await page.locator('SELECTOR').click()                     → - click: { selector: SELECTOR }
6. await page.locator('SELECTOR').fill('V')                   → - fill: { selector: SELECTOR, text: V }
```

**Snapshot insertion rule:** add a `- snapshot: {}` step before any step that uses `${refs.X}`, but NOT if the immediately-previous step was already a snapshot (avoid back-to-back). This is per design doc §3 F2 (single-key-map step shape) + the implicit contract that `${refs.X}` requires a prior snapshot.

**Out-of-scope mappings** (codegen emits these; v1 transformer either skips with a warn comment OR fails loud):
- `await page.locator('xpath=...').click()` — XPath selectors. Skip with `# TODO(flow record): unsupported xpath selector` comment.
- `await page.waitForLoadState('networkidle')` — wait verbs. Skip with comment.
- `await page.keyboard.press('Enter')` — keyboard. Map to `- press: { key: Enter }` (sub-mode addition; minimal).
- `await context.storageState({ path: ... })` — codegen's session-save. Skip; flow.yaml uses `session: NAME` instead.

**Rejected:** F6-b (full AST parse via node + esprima/acorn) — adds npm dep + ~300 LOC; regex-based mapper handles 80% of codegen's surface for v1.

### S1: Password detection = accessible-name match `/password/i` (case-insensitive)

When step is `getByRole('textbox', { name: 'X' })` or `getByLabel('X')` AND `X` matches `/password/i`, emit:

```yaml
- fill: { ref: ${refs.X}, text: ${secrets.password} }
```

Instead of the literal recorded value. **The literal value is dropped entirely** — never written to disk. The transformer emits an audit line to stderr: `flow record: redacted password field "X" → ${secrets.password} placeholder`.

The user must wire `--secret-stdin` or rotate the placeholder via `--var password=...` when running the recorded flow.

**Rejected:** S2 (strict `input[type=password]` only — codegen rarely emits the underlying input type; can't detect from JS); S3 (no detection — leaves passwords in plaintext on disk; security regression).

**Bypass for confirmed-non-password fields:** documented in cheatsheet — user can edit the recorded YAML to replace `${secrets.password}` with literal value if the field was misdetected (rare).

### W1: Recorder rejects `--tool obscura` (per design doc §12 Q6)

Codegen targets Playwright/Chrome interaction. Obscura's stateless one-shot model has no interactive recording surface. Recorder dies `EXIT_USAGE_ERROR` if `--tool obscura` is passed.

### O1: `--out FILE` REQUIRED; recorder writes only to user-specified path

No default `--out` location. Why: recorded flows are personal artifacts; user opting-in to a specific path is friction-by-design. Mirrors `creds-show --reveal` typed-phrase precedent (friction proportional to the action's permanence). Path security: realpath canonicalize + sensitive-pattern reject.

## API additions

### `scripts/lib/flow_record.sh` (new lib helper)

Three-fn API:

```bash
flow_record_transform <codegen-js-text> [out-name]
  # Pure function. Reads codegen JS on stdin OR as arg; emits flow YAML on
  # stdout. Detects password fields; emits stderr audit line per redaction.
  # Returns 0 on success; 2 if codegen JS is malformed.

flow_record_detect_password <name>
  # Returns 0 if <name> matches /password/i (case-insensitive).
  # Used internally by flow_record_transform.

flow_record_emit_step <verb> <args-yaml-flow-style>
  # Helper: prints `  - <verb>: { ... }` line. Used by transformer.
```

### `scripts/browser-flow.sh::record` (new sub-mode)

```bash
bash scripts/browser-flow.sh record --site SITE --out FILE [--name NAME] [--url URL] [--tool TOOL]
  # NEW sub-mode alongside existing `run`. Spawns playwright codegen;
  # captures stdout; calls flow_record_transform; writes ${OUT} mode 0600.
  # Emits summary with flow_name + out_file + step_count + password_redactions.
```

## Test cases (RED → GREEN)

`tests/flow-record.bats` (new file):

1. `flow_record_detect_password "Email"` → exit 1 (no match).
2. `flow_record_detect_password "Password"` → exit 0 (match).
3. `flow_record_detect_password "password"` → exit 0 (case-insensitive).
4. `flow_record_detect_password "ConfirmPassword"` → exit 0 (substring match).
5. `flow_record_transform` of a 3-line codegen fixture (goto + textbox.fill + button.click) → emits 5-line flow YAML (header + open + snapshot + fill + snapshot + click). Step count: 4 (snapshot dedup might merge to 3 — TBD).
6. `flow_record_transform` of codegen with password field → emits `${secrets.password}` placeholder; literal password absent from output.
7. `flow_record_transform` privacy canary: codegen JS contains literal "PWD-CANARY-123"; transformer output MUST NOT contain that string.
8. `flow_record_transform` with XPath selector → emits TODO comment + skips.
9. `flow_record_transform` audit line on stderr per password redaction (count + name).
10. `browser-flow.sh record --tool obscura` → EXIT_USAGE_ERROR with "recorder does not support obscura".
11. `browser-flow.sh record` without `--out` → EXIT_USAGE_ERROR.
12. `browser-flow.sh record --out FILE` (mocked playwright via env-var) → reads mock stdout; writes FILE; mode 0600; summary line emits flow_name + step_count + password_redactions.

`tests/fixtures/flow-record/` (new dir):
- `simple.codegen.js` — 3 actions (goto + fill + click).
- `with-password.codegen.js` — includes `password` field (canary literal "PWD-CANARY-9-1-iii").
- `with-xpath.codegen.js` — XPath selector to test skip-with-comment.

## Sub-scope (what 9-1-iii does NOT do)

- **No AST-based parser** — regex mapper only. Limits documented in cheatsheet.
- **No support for codegen `--target` other than `javascript`** — Python/Java/etc. emit different JS-like syntax. v1 is JS-only.
- **No secrets-management UI** — `${secrets.password}` is a literal placeholder; user wires up resolution via `--var password=X` at flow-run time. (Future iteration: pull from `~/.browser-skill/credentials/`.)
- **No round-trip validation** — recorder writes; user can run. v1 doesn't auto-run the recorded flow to verify correctness. (Future iteration: `flow record --validate` flag.)
- **No re-recording / merge** — if the user wants to extend an existing flow, they must hand-edit. v1 is greenfield-only.
- **No env-var → ${secrets.X} pull-through** — users who want session-token recording have to manually craft.
- **No `replay` / `history` / `baseline`** — those are 9-1-iv / 9-1-v.

## Acceptance

- `tests/flow-record.bats` 12+ cases all green.
- `bash tests/lint.sh` exit 0 (all three tiers).
- `flow_record_transform` of a real codegen-output sample (manually obtained from `playwright codegen https://example.com`) round-trips: transformer output is consumable by `flow run`.
- Privacy canary: literal "PWD-CANARY-9-1-iii" NEVER appears in any transformer output.
- `--tool obscura` rejected with helpful message.
- `--out FILE` required; missing `--out` → EXIT_USAGE_ERROR.
- Path security on `--out` (sensitive-pattern reject).
- CHANGELOG `[Unreleased]` `[feat]` + `[security]` tags.

## Notes for follow-ups

- **9-1-iv: `replay <id>`** — re-execute capture's steps; structured diff.
- **9-1-v: `history` + `baseline`** — read-side ops; closes Phase 9.
- **Recipe doc post-9-1-iii:** `references/recipes/flow-record-secrets.md` — codifies the password-detection + ${secrets.X} placeholder pattern. Per design doc §8.
