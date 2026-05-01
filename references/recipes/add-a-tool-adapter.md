# Recipe: Add a tool adapter

A 30-minute walkthrough for adding a new browser-automation adapter to the skill. Follow the **Path A** checklist for the initial commit; promote to default in a separate PR via **Path B**.

## When to use this recipe

Use this when adding a new browser-automation tool to the toolbox:
- `puppeteer`, `playwright-mcp`, `browserless`, etc.

Do NOT use this recipe for:
- Adding a verb (see `add-a-verb.md`).
- Changing routing precedence among existing tools (see `change-a-routing-rule.md`).

## Path A — Ship-without-promotion (zero edits to existing .sh files)

The adapter is reachable via `--tool=<name>` but is never the default for any verb. **This is the recommended way to introduce ANY new tool.** Soak-test in real workflows; promote later.

### Checklist

```
1. Create scripts/lib/tool/<tool>.sh — implement the contract:
   - Identity (3 fns):   tool_metadata, tool_capabilities, tool_doctor_check
   - Verb dispatch (8):  tool_open, tool_click, tool_fill, tool_snapshot,
                         tool_inspect, tool_audit, tool_extract, tool_eval
                         (return 41 / TOOL_UNSUPPORTED_OP for unsupported.)
   - tool_metadata.name MUST equal the filename (lint enforces).
   - tool_metadata.abi_version MUST equal BROWSER_SKILL_TOOL_ABI in common.sh.
   - The adapter MUST `source "$(dirname "${BASH_SOURCE[0]}")/../output.sh"`
     so verb output goes through emit_summary / emit_event (lint tier 3 enforces).
2. Create tests/stubs/<tool> — mock binary; logs argv to ${STUB_LOG_FILE}; returns canned JSON.
3. Create tests/fixtures/<tool>/ — JSON keyed by sha256(argv joined by NUL).
4. Create tests/<tool>_adapter.bats — contract conformance + happy-path tests.
5. Create references/<tool>-cheatsheet.md — usage notes.
6. Run scripts/regenerate-docs.sh — autogen edits references/tool-versions.md
   and the marker block in SKILL.md.
7. Add CHANGELOG entry: [adapter] added <tool> (Path A — opt-in via --tool=<tool>)
8. Run tests/run.sh and tests/lint.sh — must be green.
```

### What's NOT touched in Path A

| File | Action |
|---|---|
| `scripts/lib/router.sh` | UNTOUCHED — adapter is reachable via `--tool=<name>` only |
| `scripts/lib/common.sh` | UNTOUCHED |
| `scripts/lib/output.sh` | UNTOUCHED |
| `scripts/browser-doctor.sh` | UNTOUCHED — doctor walks `lib/tool/*.sh` automatically |
| `scripts/browser-<verb>.sh` (any) | UNTOUCHED |
| `references/routing-heuristics.md` | UNTOUCHED |

## Path B — Promote to default (run AFTER Path A ships)

Once the adapter has been validated via `--tool=<name>` in real workflows, you can promote it to default for one or more verbs.

### Checklist

```
1. Edit scripts/lib/router.sh — add a rule_<trigger> function and append it to ROUTING_RULES.
2. Update references/routing-heuristics.md — add a row matching the rule.
3. Update tests/router.bats — one positive + one negative case for the new rule.
4. Add CHANGELOG entry: [adapter] promoted <tool> to default for <trigger>.
```

## File-by-file: what every contributor sees

| File | Path A | Path B |
|---|---|---|
| `scripts/lib/tool/<tool>.sh` | **CREATE** | (untouched) |
| `tests/stubs/<tool>` | **CREATE** | (untouched) |
| `tests/fixtures/<tool>/` | **CREATE** | (untouched) |
| `tests/<tool>_adapter.bats` | **CREATE** | (untouched) |
| `references/<tool>-cheatsheet.md` | **CREATE** | (untouched) |
| `scripts/lib/router.sh` | (untouched) | **EDIT** (one fn + one array append) |
| `scripts/lib/common.sh` | (untouched) | (untouched) |
| `scripts/lib/output.sh` | (untouched) | (untouched) |
| `scripts/browser-doctor.sh` | (untouched) | (untouched) |
| `scripts/browser-<verb>.sh` | (untouched) | (untouched) |
| `references/tool-versions.md` | **AUTOGEN** | (autogen) |
| `SKILL.md` | **AUTOGEN** (between markers) | (untouched) |
| `references/routing-heuristics.md` | (untouched) | **EDIT** (one row) |
| `tests/router.bats` | (untouched) | **EDIT** (positive + negative) |
| `CHANGELOG.md` | **EDIT** (one line) | **EDIT** (one line) |

**Path A is 5 creates + 2 autogen + 1 changelog line, with zero edits to .sh files in core.**

## Worked example: adding `puppeteer-via-bridge` in 30 minutes

```bash
# 1. Scaffold from playwright-cli (similar shape)
cp scripts/lib/tool/playwright-cli.sh scripts/lib/tool/puppeteer.sh

# 2. Edit puppeteer.sh:
#    - sentinel guard: _BROWSER_TOOL_PUPPETEER_LOADED
#    - readonly _BROWSER_TOOL_PUPPETEER_BIN="${PUPPETEER_BIN:-puppeteer}"
#    - tool_metadata.name = "puppeteer", cheatsheet_path = "references/puppeteer-cheatsheet.md"
#    - tool_capabilities: declare what puppeteer actually supports
#    - tool_doctor_check: command -v puppeteer; install hint = "npm i -g puppeteer"
#    - tool_open / tool_click / tool_fill / tool_snapshot / tool_inspect: shell to puppeteer
#    - tool_audit / tool_extract / tool_eval: return 41

# 3. Stub + fixtures (copy & adapt)
cp tests/stubs/playwright-cli tests/stubs/puppeteer
mkdir tests/fixtures/puppeteer

# 4. Test (copy & adapt)
cp tests/playwright-cli_adapter.bats tests/puppeteer_adapter.bats
sed -i.bak 's/playwright-cli/puppeteer/g' tests/puppeteer_adapter.bats
rm tests/puppeteer_adapter.bats.bak

# 5. Cheatsheet
cp references/playwright-cli-cheatsheet.md references/puppeteer-cheatsheet.md
# (edit the cheatsheet content for puppeteer specifics)

# 6. Regen autogen docs
scripts/regenerate-docs.sh all

# 7. Test the lot
tests/run.sh
tests/lint.sh

# 8. CHANGELOG
echo "- [adapter] added puppeteer adapter (Path A — opt-in via --tool=puppeteer)" >> CHANGELOG.md

# 9. Commit
git add -A
git commit -m "feat(tool): puppeteer adapter (Path A — opt-in)"
```

## See also

- [Anti-patterns: tool extension](anti-patterns-tool-extension.md) — what NOT to do.
- [Tool adapter extension model spec](../../docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md) — the *why*.
- [Token-efficient adapter output spec](../../docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md) — `eN` refs, capture paths, single-line summaries.
- [Routing heuristics](../routing-heuristics.md) — current precedence table.
