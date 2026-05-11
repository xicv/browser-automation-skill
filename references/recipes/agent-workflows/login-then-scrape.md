# Workflow: login then scrape

**Goal:** register a site, capture an authenticated session, scrape multiple URLs from it.

**Outcome:** a single `obscura` adapter call returns JSON for N URLs, all using the same logged-in cookie state from a Playwright `storageState`. Zero LLM tokens after step 4.

## Prerequisites

- Clean `~/.browser-skill/` (or skip step 0 if already installed).
- At least one adapter installed (`chrome-devtools-mcp` recommended for login capture; `obscura` for bulk scrape).
- The target site has username+password login (TOTP optional).

## Steps

### 0. Install (one-time)

```bash
git clone https://github.com/xicv/browser-automation-skill ~/Projects/browser-automation-skill
cd ~/Projects/browser-automation-skill
./install.sh --with-hooks   # --with-hooks installs the credential-leak pre-commit blocker
bash scripts/browser-doctor.sh
# → expect: "ok: all checks passed (4 adapter(s) ok)" if all 4 adapters installed
```

### 1. Register the site

```bash
bash scripts/browser-add-site.sh --name acme --url 'https://app.acme.com'
bash scripts/browser-use.sh --set acme
# → sticky "current site" set; subsequent verbs can omit --site
```

### 2. Store credentials (stdin-only; never on argv)

```bash
printf '%s' 'your-password' | bash scripts/browser-creds-add.sh \
  --site acme --as acme--admin \
  --password-stdin \
  --auth-flow single-step-username-password
# → keychain (macOS) or libsecret (Linux) by default; plaintext requires typed-phrase
```

If TOTP is required:

```bash
printf '%s' 'BASE32SECRET' | bash scripts/browser-creds-add.sh \
  --site acme --as acme--admin \
  --totp-secret-stdin \
  --auth-flow single-step-username-password-with-totp
```

### 3. Interactive login (one-time; captures `storageState`)

```bash
bash scripts/browser-login.sh \
  --site acme --as acme--admin \
  --interactive
# → opens a real browser; fill the login form; press Enter in the terminal
# → captures cookies + localStorage into ~/.browser-skill/sessions/acme--admin.json
```

After this, all subsequent verbs can pass `--as acme--admin` to reuse the session.

### 4. Bulk scrape

```bash
bash scripts/browser-extract.sh --site acme --as acme--admin \
  --scrape \
    'https://app.acme.com/orders/1001' \
    'https://app.acme.com/orders/1002' \
    'https://app.acme.com/orders/1003' \
  --eval 'document.querySelector(".order-total")?.textContent' \
  --format json
# → streams 3 JSON events (one per URL) + a summary line
# → routed to obscura adapter via the rule_scrape_flag router rule
```

## Verification

```bash
# Confirm session was captured + is mode 0600.
bash scripts/browser-list-sessions.sh --site acme
# → table includes acme--admin

# Confirm session file mode.
ls -la ~/.browser-skill/sessions/
# → expect: -rw------- (mode 0600) on acme--admin.json
```

## Next steps

- Want to scrape 50+ URLs? See [`cache-driven-bulk-operation.md`](cache-driven-bulk-operation.md).
- Want to record + replay a multi-step interaction? See [`flow-record-and-replay.md`](flow-record-and-replay.md).
- The login flow auto-detects 2FA prompts; for non-interactive re-login, see `browser-login.sh --help`.

## Don't

- **Don't pass `--password` or `--totp` on argv.** Always use `--password-stdin` / `--totp-secret-stdin`. The pre-commit hook + tests/argv_leak.bats enforce this; bypassing leaks secrets into `ps`, shell history, and the Claude transcript.
- **Don't commit `~/.browser-skill/`** to git. `.gitignore` blocks the pattern; verify with `git check-ignore ~/.browser-skill/credentials/foo.json`.
- **Don't store credentials with `--backend plaintext`** unless the typed-phrase confirms understanding. Keychain (macOS) / libsecret (Linux) is the default — let it stay default.
