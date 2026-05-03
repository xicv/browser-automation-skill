# Phase 5 part 2d-iii — `mask.sh` + `creds show --reveal` + first-use plaintext gate

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Close the security/UX gaps in the auth track. Three concerns in one PR:

1. **`scripts/lib/mask.sh`** — reusable masking helper. `mask_string VAL` → `"p*********3"`. Used by `creds show --reveal` to display a masked preview alongside the unmask, and reusable for any future verb that needs to render a sensitive value safely.
2. **`creds show --reveal`** — typed-phrase confirmation flow. Default `creds show` already emits metadata only (privacy invariant from part 2d-ii). Adding `--reveal` requires the user to type the credential name back via stdin; on match, the secret is fetched (via `credential_get_secret`) and emitted alongside its masked form. On mismatch, the verb dies with a self-healing hint.
3. **First-use plaintext gate** — per parent spec §1, plaintext storage is paper-security without disk encryption. `creds add --backend plaintext` (or auto-detected plaintext) on a system without a previous plaintext acknowledgment must require an explicit `--yes-i-know-plaintext` flag. After the first acknowledged add, a marker file `${CREDENTIALS_DIR}/.plaintext-acknowledged` (mode 0600) lets subsequent adds proceed without re-acknowledgment.

**Branch:** `feature/phase-05-part-2d-iii-mask-and-reveal`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/lib/mask.sh` | `mask_string VAL [SHOW_FIRST=1] [SHOW_LAST=1]` — reusable masking helper | ≤ 80 LOC |
| `tests/mask.bats` | Unit tests for `mask_string` | ≤ 100 LOC |
| `docs/superpowers/plans/2026-05-03-phase-05-part-2d-iii-mask-and-reveal.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/browser-creds-show.sh` | Add `--reveal` flag + typed-phrase confirmation; emit `secret_masked` + `secret` keys when revealed; mode shifts from `why=show` to `why=reveal` | +~40 LOC |
| `scripts/browser-creds-add.sh` | Add `--yes-i-know-plaintext` flag + first-use marker check; die with hint when plaintext + marker missing + flag missing; touch marker on successful add | +~25 LOC |
| `tests/creds-show.bats` | ~5 new cases: `--reveal` happy path with typed-phrase, `--reveal` refusal on mismatch, `--reveal` includes secret value, masked preview shape, missing typed-phrase exits non-zero | +~80 LOC |
| `tests/creds-add.bats` | ~4 new cases: plaintext gate refuses without flag, `--yes-i-know-plaintext` bypasses, marker created on success, subsequent adds skip the gate. Existing tests get `--yes-i-know-plaintext` flag where they use plaintext backend (or pre-create marker in setup) | +~50 LOC |
| `SKILL.md` | Update `creds add` row (note about `--yes-i-know-plaintext`); update `creds show` row (note about `--reveal`) | +~2 LOC |
| `CHANGELOG.md` | New `### Phase 5 part 2d-iii` subsection | +~12 LOC |

### Untouched

- `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`
- `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`
- `scripts/browser-doctor.sh`, `scripts/browser-creds-list.sh`, `scripts/browser-creds-remove.sh`
- every adapter file
- `tests/lint.sh`

---

## Task 1: `mask.sh` lib + tests

API:
```bash
mask_string VAL [SHOW_FIRST=1] [SHOW_LAST=1]
# "password123"           → "p*********3"
# "ab"                     → "**"
# "x"                      → "*"
# ""                       → ""
# "secret_token_abc"       → "s**************c"
# "very-long-...-80-chars" → first + cap-80-stars + last
```

Rules:
- `len <= SHOW_FIRST + SHOW_LAST` → all stars (no leak of any chars)
- Middle is replaced with `len - SHOW_FIRST - SHOW_LAST` stars
- Cap middle at 80 stars to keep masked rendering bounded for huge tokens
- Empty input → empty output

Tests (~6 cases):
- standard 11-char string with defaults
- 2-char string → all stars
- 1-char string → single star
- empty string → empty
- custom SHOW_FIRST=2 SHOW_LAST=2
- very-long string (200 chars) → masked stays bounded

---

## Task 2: `creds show --reveal` flow

Add to `scripts/browser-creds-show.sh`:
```bash
reveal=0
while [ $# -gt 0 ]; do
  case "$1" in
    --as)     name="$2"; shift 2 ;;
    --reveal) reveal=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
```

Reveal flow:
1. Standard validation: `--as` required, name safe, credential exists.
2. If `--reveal`:
   - Print typed-phrase prompt to stderr: `"Type the credential name (NAME) to confirm reveal: "`
   - Read one line from stdin (`IFS= read -r answer`)
   - If `answer != name`: `die EXIT_USAGE_ERROR "reveal aborted (confirmation mismatch)"`
   - Source `mask.sh`; fetch secret via `credential_get_secret NAME`; compute `secret_masked`
   - Emit JSON with `meta` + `secret_masked` + `secret` keys; `why=reveal`
3. If NOT `--reveal`: existing metadata-only path (`why=show`).

Tests:
- `--reveal` with matching typed-phrase → secret + secret_masked present
- `--reveal` with mismatch → exit non-zero
- `--reveal` output secret_masked has expected shape (first/last chars)
- `--reveal` happy path also includes meta (not just secret)
- without `--reveal` (existing): no secret key (regression guard)

---

## Task 3: First-use plaintext gate in `creds add`

Add to `scripts/browser-creds-add.sh`:
- New flag: `--yes-i-know-plaintext`
- After backend resolution, before `credential_save`:
  ```bash
  if [ "${backend}" = "plaintext" ]; then
    marker="${CREDENTIALS_DIR}/.plaintext-acknowledged"
    if [ ! -f "${marker}" ]; then
      if [ "${yes_plaintext}" -ne 1 ]; then
        die "${EXIT_USAGE_ERROR}" "first plaintext credential requires --yes-i-know-plaintext (or pre-create ${marker}); see docs/security.md"
      fi
      mkdir -p "${CREDENTIALS_DIR}"
      ( umask 077; : > "${marker}" )
      chmod 600 "${marker}"
    fi
  fi
  ```

Tests:
- plaintext + no flag + no marker → exit 2 with hint
- plaintext + flag + no marker → succeeds + marker created
- plaintext + marker pre-existing + no flag → succeeds (silent)
- plaintext + flag + marker pre-existing → succeeds (no-op on marker)

Existing tests (creds-add.bats) using plaintext backend will need either:
- pass `--yes-i-know-plaintext` inline, OR
- pre-create the marker in `setup()`

I'll choose **pre-create marker in setup()** — it's the test-suite hygiene equivalent of "user has already acknowledged plaintext at install time." Mirrors how `setup_temp_home` initializes a clean state.

---

## Task 4: SKILL.md + CHANGELOG + lint + ship

Updates:
- SKILL.md `creds add` row: append "; first plaintext use needs `--yes-i-know-plaintext`"
- SKILL.md `creds show` row: append "; `--reveal` after typed-phrase confirms"
- CHANGELOG: full subsection
- Lint exit 0
- Tests ≥421 pass / 0 fail (405 + ~6 mask + ~5 reveal + ~4 plaintext gate + ~1 misc = ~16)

---

## Acceptance criteria

- [ ] `scripts/lib/mask.sh` exists; `mask_string` covers short/long/empty/custom-bounds.
- [ ] `creds show --reveal` requires typed-phrase; emits `secret_masked` + `secret`.
- [ ] `creds show` (without `--reveal`) unchanged — privacy invariant guarded by existing canary.
- [ ] `creds add` first plaintext use refused without `--yes-i-know-plaintext`; marker created on first acknowledged add.
- [ ] `creds add` non-plaintext (keychain/libsecret) unaffected by the gate.
- [ ] `bash tests/lint.sh` exit 0.
- [ ] `bash tests/run.sh` ≥421 pass / 0 fail.
- [ ] CI green on macos-latest + ubuntu-latest.

---

## Out of scope (defer)

| Item | Goes to |
|---|---|
| Interactive `read -s` password prompt for `creds add` (no `--password-stdin` required) | follow-up (TTY mocking in bats is complex; may never come — `--password-stdin` is fine UX) |
| `creds rotate-totp` verb | Phase 5 part 4 (TOTP) |
| `migrate-credential` cross-backend moves | Phase 5 part 2e |
| Auto-relogin (single-retry on EXIT_SESSION_EXPIRED) | Phase 5 part 3 |
| `references/security.md` doc (referenced from the gate's error message) | exists in parent spec roadmap; full content lands when capture-sanitization arrives in Phase 7 |
