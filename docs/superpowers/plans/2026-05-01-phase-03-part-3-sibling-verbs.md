# Phase 3 Part 3 — Sibling verb scripts (snapshot, click, fill, inspect)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Land the four sibling verb scripts (`snapshot`, `click`, `fill`, `inspect`) that complete the navigation/inspection verb surface declared by the playwright-cli adapter. Each follows the **same template** as `scripts/browser-open.sh` (Phase 3 part 2): parse globals → `pick_tool` → `source_picked_adapter` → `tool_<verb>` → `emit_summary`.

**Tech stack:** Bash 4+, jq, bats-core, the existing playwright-cli stub. Three new stub fixtures cover the new argv shapes; one extra `--secret-stdin` test for the fill verb proves no-secrets-in-argv (AP-7).

**Spec references:**
- Parent spec §3.2 (verb scripts), §5.4 (summary contract).
- Token-efficient output spec §3 (output schema), §5 (`eN` refs).
- Adapter `tool_capabilities` declares: `snapshot { flags: [] }`, `click { flags: [--ref, --selector] }`, `fill { flags: [--ref, --text, --secret-stdin] }`, `inspect { flags: [--selector] }`.

**Branch:** `feature/phase-03-part-3-sibling-verbs`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/browser-snapshot.sh` | snapshot DOM via picked adapter; emit `eN`-indexed result | ≤ 100 LOC |
| `scripts/browser-click.sh` | click by `--ref eN` or `--selector CSS` | ≤ 100 LOC |
| `scripts/browser-fill.sh` | fill input by `--ref eN` with `--text` or `--secret-stdin` | ≤ 120 LOC |
| `scripts/browser-inspect.sh` | inspect element by `--selector CSS` | ≤ 100 LOC |
| `tests/browser-snapshot.bats` | snapshot verb tests | ≤ 120 LOC |
| `tests/browser-click.bats` | click verb tests | ≤ 120 LOC |
| `tests/browser-fill.bats` | fill verb tests + secret-leak guard | ≤ 150 LOC |
| `tests/browser-inspect.bats` | inspect verb tests | ≤ 120 LOC |
| `tests/fixtures/playwright-cli/<hash-fill>.json` | fixture for `fill --ref e3 --text hello` | small |
| `tests/fixtures/playwright-cli/<hash-inspect>.json` | fixture for `inspect --selector h1` | small |

(`snapshot` and `click --ref e3` fixtures already exist from Phase 3 framework Task 6.)

### Modified

| Path | Change |
|---|---|
| `SKILL.md` | Verbs table gains 4 rows |
| `CHANGELOG.md` | Phase-3-part-3 subsection |

---

## Pre-Plan: branch + commit plan

- [ ] **Step 0.1** Branch from main → `feature/phase-03-part-3-sibling-verbs`.
- [ ] **Step 0.2** Commit plan: `docs: phase-3 part 3 plan — sibling verbs`.

---

## Task 1: browser-snapshot.sh

**Files:** Create `scripts/browser-snapshot.sh` + `tests/browser-snapshot.bats`.

Verb argv: optional `--depth N` (per token-eff spec §4). No required args. Adapter expects bare `snapshot` (or `snapshot --depth N`).

- [ ] **Step 1.1** Write failing bats: 4 cases (passes through to stub, summary keys, --tool override, --dry-run).
- [ ] **Step 1.2** Run RED.
- [ ] **Step 1.3** Write `scripts/browser-snapshot.sh` (template = browser-open.sh; verb=snapshot; no required arg).
- [ ] **Step 1.4** Run GREEN.
- [ ] **Step 1.5** Commit: `feat(verb): browser-snapshot.sh — snapshot via picked adapter`.

---

## Task 2: browser-click.sh

**Files:** Create `scripts/browser-click.sh` + `tests/browser-click.bats`.

Verb argv: `--ref eN` OR `--selector CSS` (mutually exclusive; one required).

- [ ] **Step 2.1** Write failing bats: 5 cases (--ref pass-through, summary, --selector path, missing both fails, both supplied fails).
- [ ] **Step 2.2** Run RED.
- [ ] **Step 2.3** Write `scripts/browser-click.sh`.
- [ ] **Step 2.4** Run GREEN.
- [ ] **Step 2.5** Commit: `feat(verb): browser-click.sh — click by --ref eN or --selector CSS`.

---

## Task 3: browser-fill.sh

**Files:** Create `scripts/browser-fill.sh` + `tests/browser-fill.bats` + 1 stub fixture.

Verb argv: `--ref eN` (required) + (`--text VALUE` XOR `--secret-stdin`).

Critical: `--secret-stdin` reads the secret from stdin, NEVER puts it on argv. The bats test asserts the stub's argv log does NOT contain the secret string.

- [ ] **Step 3.1** Compute argv hash for `fill --ref e3 --text hello`; create the fixture.
- [ ] **Step 3.2** Write failing bats: 6 cases (--text pass-through, summary, --secret-stdin reads-then-pipes-stdin, secret-not-in-argv leak guard, missing --ref fails, both --text and --secret-stdin supplied fails).
- [ ] **Step 3.3** Run RED.
- [ ] **Step 3.4** Write `scripts/browser-fill.sh`.
- [ ] **Step 3.5** Run GREEN.
- [ ] **Step 3.6** Commit: `feat(verb): browser-fill.sh — fill by --ref + (--text|--secret-stdin); secret never in argv`.

---

## Task 4: browser-inspect.sh

**Files:** Create `scripts/browser-inspect.sh` + `tests/browser-inspect.bats` + 1 stub fixture.

Verb argv: `--selector CSS` (required).

- [ ] **Step 4.1** Compute argv hash for `inspect --selector h1`; create the fixture.
- [ ] **Step 4.2** Write failing bats: 4 cases (pass-through, summary, missing --selector fails, --tool override).
- [ ] **Step 4.3** Run RED.
- [ ] **Step 4.4** Write `scripts/browser-inspect.sh`.
- [ ] **Step 4.5** Run GREEN.
- [ ] **Step 4.6** Commit: `feat(verb): browser-inspect.sh — inspect by --selector CSS`.

---

## Task 5: SKILL.md verb table + CHANGELOG + tag

- [ ] **Step 5.1** Add 4 rows to `SKILL.md` verbs table.
- [ ] **Step 5.2** Append CHANGELOG entry under `## [Unreleased]` → `### Phase 3 part 3`.
- [ ] **Step 5.3** Run full suite + lint — must be green.
- [ ] **Step 5.4** Commit + tag `v0.3.2-phase-03-part-3-sibling-verbs`.

---

## Acceptance criteria

- [ ] All four verbs run end-to-end through the stub: each prints adapter streaming line + single-line JSON summary.
- [ ] Full `tests/run.sh` green.
- [ ] `bash tests/lint.sh` exit 0 (all three tiers).
- [ ] `tests/browser-fill.bats::secret-not-in-argv` proves the secret string never appears in `${STUB_LOG_FILE}` after `--secret-stdin` use.
- [ ] CI green on macos-latest + ubuntu-latest.
