# Phase 5 part 3 — `login --auto` auto-relogin from stored credentials

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Compound the user-visible value of the credentials track: `login --auto --site SITE --as CRED` performs a programmatic headless login using the stored credential, refreshing the session without TTY interaction. Until now, stored creds saved typing only conceptually — the user had to manually re-login on session expiry. This PR makes them actually save typing.

**Out of scope (deferred to follow-ups):**
- **Transparent verb-retry on `EXIT_SESSION_EXPIRED`** (parent spec §4.4 invariant) — the "every verb call → silent re-login → retry" flow lives in `verb_helpers::resolve_session_storage_state`. Adding it requires careful retry-budget tracking ("exactly one"). **Phase 5 part 3-ii.**
- **Auth-flow detection at `creds add` time** — currently part 2d hardcodes `auth_flow: "single-step-username-password"`. Real detection (observe form selectors at add time, replay them at relogin time) is significant scope. **Phase 5 part 3-iii.** For Part 3, we use best-effort form selectors at relogin time.
- **2FA detection** (parent spec §4.4: "if 2FA detected → exit 25") — needs interactive-required heuristic. **Phase 5 part 3-iv.**

**Test strategy — verb-side validation only.** Mirroring how `login --interactive` is tested (existing `tests/login.bats`): bats covers verb-side argument validation, mutual-exclusivity, dry-run path, and credential-existence checks. The driver's real-mode auto-relogin code path (headless chromium + form fill) has no bats coverage in this PR — same gating as `--interactive` real-mode. Manual / future-CI integration test gated by `command -v playwright`.

**Branch:** `feature/phase-05-part-3-auto-relogin`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `docs/superpowers/plans/2026-05-03-phase-05-part-3-auto-relogin.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/lib/node/playwright-driver.mjs` | Add `auto-relogin` verb dispatch + `runAutoRelogin(flags)` real-mode implementation. Reads NUL-separated `username\0password` from stdin. Launches headless chromium, navigates URL, fills best-effort selectors, clicks submit, waits, captures `storageState`, writes to `--output-path`. | +~110 LOC |
| `scripts/browser-login.sh` | Drop the "reserved for Phase 5" guard; add `--auto` flag implementation. Validates `--site` + `--as` required. Loads credential, validates `auto_relogin=true` + `account` non-empty. Loads secret via `credential_get_secret`. Sends `username\0password` to driver via stdin. Tempfile + same validate/save pipeline as `--interactive`. Mutually exclusive with `--interactive` and `--storage-state-file`. | +~75 LOC, -~5 LOC |
| `tests/login.bats` | New `--auto` cases (~7): mutex with --interactive, mutex with --storage-state-file, requires --site, requires --as, refuses missing cred (exit 23), refuses cred with auto_relogin=false, --dry-run path | +~120 LOC |
| `SKILL.md` | Add `login --auto` row | +~1 LOC |
| `CHANGELOG.md` | New `### Phase 5 part 3` subsection | +~12 LOC |

### Untouched

- `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`
- `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`
- `scripts/lib/verb_helpers.sh` (transparent verb-retry deferred to part 3-ii)
- `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`
- `scripts/lib/tool/*.sh`, `scripts/lib/node/chrome-devtools-bridge.mjs`
- `scripts/browser-doctor.sh`, every `scripts/browser-creds-*.sh`, every other `scripts/browser-*.sh`
- every other adapter file
- `tests/lint.sh`

---

## Pre-Plan: branch + plan commit

- [x] **Step 0.1** Branch `feature/phase-05-part-3-auto-relogin`.
- [ ] **Step 0.2** Commit plan.

---

## Task 1: Driver `runAutoRelogin`

Add to `playwright-driver.mjs`:
- New case in `realDispatch`'s switch: `case 'auto-relogin': return await runAutoRelogin(flags);`
- New function `runAutoRelogin(flags)`:

```js
async function runAutoRelogin(flags) {
  const url = flags.url;
  const outputPath = flags['output-path'];
  if (!url) { /* exit 2 */ }
  if (!outputPath) { /* exit 2 */ }

  const credsBlob = await readAllStdin();
  const sep = credsBlob.indexOf('\0');
  if (sep === -1) {
    process.stderr.write("playwright-driver.mjs::auto-relogin: stdin must be 'username\\0password'\n");
    process.exit(2);
  }
  const username = credsBlob.slice(0, sep);
  const password = credsBlob.slice(sep + 1);

  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ headless: true });
  try {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    // Best-effort selectors. Sites vary wildly; this works for common forms
    // (Google-style, generic email+password, label-based). Selectors are
    // tried in order; first match wins.
    const usernameSelectors = [
      'input[type=email]',
      'input[name=email]',
      'input[name=username]',
      'input[autocomplete=username]',
      'input#email',
      'input#username',
    ];
    const passwordSelectors = [
      'input[type=password]',
      'input[name=password]',
      'input[autocomplete=current-password]',
      'input#password',
    ];
    const submitSelectors = [
      'button[type=submit]',
      'input[type=submit]',
      'button:has-text("Sign in")',
      'button:has-text("Log in")',
      'button:has-text("Login")',
    ];

    await fillFirstMatch(page, usernameSelectors, username);
    await fillFirstMatch(page, passwordSelectors, password);
    await clickFirstMatch(page, submitSelectors);

    // Wait for navigation OR network idle; whichever comes first.
    await Promise.race([
      page.waitForLoadState('networkidle', { timeout: 15000 }),
      page.waitForURL((u) => u.toString() !== url, { timeout: 15000 }),
    ]).catch(() => { /* both timed out — capture whatever state we have */ });

    const state = await ctx.storageState();
    mkdirSync(dirname(outputPath), { recursive: true, mode: 0o700 });
    writeFileSync(outputPath, JSON.stringify(state, null, 2));
    chmodSync(outputPath, 0o600);

    process.stdout.write(JSON.stringify({
      event: 'auto-relogin-saved',
      output_path: outputPath,
      cookie_count: state.cookies.length,
      origin_count: state.origins.length,
    }) + '\n');

    await browser.close();
    process.exit(0);
  } catch (err) {
    try { await browser.close(); } catch (_) {}
    process.stderr.write(
      `playwright-driver.mjs::auto-relogin: ${err && err.message ? err.message : err}\n`
    );
    process.exit(30);
  }
}

async function fillFirstMatch(page, selectors, value) {
  for (const sel of selectors) {
    const el = page.locator(sel).first();
    if (await el.count() > 0) {
      await el.fill(value);
      return;
    }
  }
  throw new Error(`auto-relogin: no matching input among [${selectors.join(', ')}]`);
}

async function clickFirstMatch(page, selectors) {
  for (const sel of selectors) {
    const el = page.locator(sel).first();
    if (await el.count() > 0) {
      await el.click();
      return;
    }
  }
  throw new Error(`auto-relogin: no matching submit button among [${selectors.join(', ')}]`);
}
```

Stub mode unchanged — fixture lookup applies to `auto-relogin` argv just like any other verb.

---

## Task 2: `browser-login.sh --auto` flag

Replace the existing "reserved" guard with the implementation:

```bash
# --auto requires --site + --as + a credential with auto_relogin=true.
# Mutually exclusive with --interactive and --storage-state-file.
if [ "${auto}" -eq 1 ]; then
  if [ "${interactive}" -eq 1 ]; then
    die "${EXIT_USAGE_ERROR}" "--auto and --interactive are mutually exclusive"
  fi
  if [ -n "${ss_file}" ]; then
    die "${EXIT_USAGE_ERROR}" "--auto and --storage-state-file are mutually exclusive"
  fi
fi
# (existing validation continues)

# After --as is resolved + site is loaded:
if [ "${auto}" -eq 1 ]; then
  source "${SCRIPT_DIR}/lib/credential.sh"

  if ! credential_exists "${as}"; then
    die "${EXIT_SITE_NOT_FOUND}" "credential not found: ${as} (run: creds-add --site ${site} --as ${as} --password-stdin)"
  fi

  cred_meta="$(credential_load "${as}")"
  cred_site="$(printf '%s' "${cred_meta}" | jq -r .site)"
  cred_account="$(printf '%s' "${cred_meta}" | jq -r .account)"
  cred_auto="$(printf '%s' "${cred_meta}" | jq -r .auto_relogin)"

  if [ "${cred_site}" != "${site}" ]; then
    die "${EXIT_USAGE_ERROR}" "credential ${as} is bound to site ${cred_site}, not ${site}"
  fi
  if [ "${cred_auto}" != "true" ]; then
    die "${EXIT_USAGE_ERROR}" "credential ${as} has auto_relogin=false; cannot --auto"
  fi
  if [ -z "${cred_account}" ]; then
    die "${EXIT_USAGE_ERROR}" "credential ${as} has empty account"
  fi

  if [ "${dry_run}" -eq 1 ]; then
    ok "dry-run: would auto-relogin ${as} (site=${site}, account=${cred_account})"
    duration_ms=$(( $(now_ms) - started_at_ms ))
    summary_json verb=login tool=playwright-lib why=auto-relogin-dry-run status=ok would_run=true \
                 site="${site}" session="${as}" account="${cred_account}" \
                 duration_ms="${duration_ms}"
    exit "${EXIT_OK}"
  fi

  mkdir -p "${SESSIONS_DIR}"
  chmod 700 "${SESSIONS_DIR}"
  ss_file="${SESSIONS_DIR}/${as}.auto-tmp.$$"

  ok "auto-relogin: launching headless Chromium at ${site_url} as ${cred_account}"

  # Pipe username\0password to driver stdin. AP-7: secret never on argv.
  if ! { printf '%s\0' "${cred_account}"; credential_get_secret "${as}"; } | \
       node "${SCRIPT_DIR}/lib/node/playwright-driver.mjs" auto-relogin \
         --url "${site_url}" --output-path "${ss_file}"; then
    rm -f "${ss_file}"
    die "${EXIT_TOOL_CRASHED}" "auto-relogin failed (driver returned non-zero)"
  fi
fi
```

Then the existing validate-and-save pipeline runs (reads `ss_file`, validates origins, saves session). At end, the summary's `why_tag` becomes `"auto-relogin"`.

Note: `printf '%s\0' "${cred_account}"` writes account followed by NUL. Then `credential_get_secret "${as}"` writes the password (verbatim, no trailing newline because `cat` in plaintext backend / `find-generic-password -w` in keychain doesn't append). Combined stdin: `account\0password`.

---

## Task 3: Tests in `tests/login.bats`

7 new cases (mirror `--interactive` validation patterns):
1. `--auto` and `--interactive` mutually exclusive (exit 2)
2. `--auto` and `--storage-state-file` mutually exclusive (exit 2)
3. `--auto` requires `--site` (exit 2)
4. `--auto` requires `--as` (exit 2 if site has no default_session)
5. `--auto` refuses missing credential (exit 23)
6. `--auto` refuses credential with `auto_relogin=false` (exit 2)
7. `--auto --dry-run` reports planned action without driver invocation

Defensive setup: each `--auto` test that creates a credential exports keychain + libsecret stubs (preserves the lesson from part 2b).

No driver-execution tests — same gating as `--interactive` (real-mode test deferred to manual / future-CI).

---

## Task 4: SKILL.md + CHANGELOG + lint + ship

- SKILL.md row: `| login --auto | Auto-relogin from stored credential (headless; AP-7 stdin-only) | printf 'pw' \| ... actually account+password... | actually... |`
  Simpler: `| login (auto) | Programmatic headless login using stored creds | … login --site prod --as prod--admin --auto |`
- CHANGELOG entry summarizing flag + driver extension + privacy + best-effort selectors + deferred items
- Lint exit 0
- Tests ≥458 pass / 0 fail (451 + 7 new)

---

## Acceptance criteria

- [ ] `playwright-driver.mjs::runAutoRelogin` exists; reads stdin NUL-separated; uses best-effort form selectors.
- [ ] `browser-login.sh --auto` validates: cred exists, cred bound to --site, auto_relogin=true, account non-empty.
- [ ] `--auto` mutually exclusive with `--interactive` + `--storage-state-file`.
- [ ] `--auto --dry-run` skips driver invocation.
- [ ] Privacy: password reaches driver via stdin only (AP-7); never argv.
- [ ] `bash tests/lint.sh` exit 0.
- [ ] `bash tests/run.sh` ≥458 pass / 0 fail.
- [ ] CI green on macos-latest + ubuntu-latest.

---

## Out of scope (defer with named follow-ups)

| Item | Goes to |
|---|---|
| Transparent verb-retry on `EXIT_SESSION_EXPIRED` (every-verb-call silent re-login per parent spec §4.4) | **Phase 5 part 3-ii** |
| Auth-flow detection at `creds add` time (record actual selectors used by site's login form so relogin can replay them) | **Phase 5 part 3-iii** |
| 2FA detection → exit 25 (per parent spec §4.4) | **Phase 5 part 3-iv** |
| Real headless-browser bats tests (no stub) | optional follow-up gated by `command -v playwright` on CI |
| TOTP integration with auto-relogin (RFC 6238) | Phase 5 part 4 |

---

## Risk register

| Risk | Mitigation |
|---|---|
| Best-effort selectors miss site's actual form (login fails) | Driver throws clear error message naming the selector list. User can re-run interactive `login` to refresh manually. Real fix is auth-flow detection at creds-add time (part 3-iii). |
| `printf '%s\0' "${account}"` followed by `credential_get_secret` doesn't produce exactly NUL-separated stdin (e.g. plaintext backend writes trailing newline) | plaintext backend's `secret_get` is `cat <file>` — preserves whatever bytes the user piped to `secret_set`. If user piped `printf 'pw'` (no newline), no newline. If they piped `echo 'pw'`, there's a newline. Document the convention. |
| Headless chromium login bypasses 2FA detection silently → captures incomplete session | Out of scope for this PR (part 3-iv). Until then, users with 2FA-enabled accounts shouldn't set `auto_relogin=true` at creds-add time. |
| `--auto` looks superficially similar to `--interactive` and users confuse them | SKILL.md row clarifies. Cheatsheet (when written) explains the trade-off. |
| Stub mode for auto-relogin not exercised by any test (regression risk) | Verb-side bats covers the validation surface. Driver real-mode is gated like `--interactive`'s. Same risk profile as existing interactive flow — accepted. |
