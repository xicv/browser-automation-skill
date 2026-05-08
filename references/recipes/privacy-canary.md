# Recipe: Privacy canary

A sentinel-byte regression test for any verb that ingests caller-supplied secrets (passwords, tokens, TOTP shared-secrets, session storage state). Detects the day a refactor accidentally re-emits the secret on stdout, in a log line, or inside a JSON reply.

## When to use this recipe

Use this **whenever you add a verb that reads a secret via stdin** (the AP-7 pattern — see `anti-patterns-tool-extension.md::AP-7`). Examples already shipped:

- `tests/creds-show.bats::49` — `creds show` invariant.
- `tests/creds-migrate.bats::124` — backend transfer mustn't echo.
- `tests/creds-rotate-totp.bats::99` — TOTP shared-secret roundtrip.
- `tests/chrome-devtools-mcp_daemon_e2e.bats::140` — `fill --secret-stdin` end-to-end.

Do NOT use this recipe for:
- Verbs that don't ingest secrets (the canary has nothing to detect).
- Verbs whose only "secret" is something the agent typed and is happy to read back (e.g. `route fulfill --body` — see `body-bytes-not-body.md` instead; the body is content, not a credential).

## The pattern

```
WRONG — assert "secret didn't appear in some specific field"
@test "fill --secret-stdin: reply has no .text key" {
  printf 'pw' | bash browser-fill.sh --ref e1 --secret-stdin
  printf '%s' "$output" | jq -e '.text == null' >/dev/null
}
# Brittle: only catches a single regression mode (echoing in a known field).
# A new code path that puts the secret into a NEW field passes this test.
```

```
RIGHT — assert "this exact byte sequence does not appear ANYWHERE on stdout"
@test "fill --secret-stdin: privacy canary" {
  CANARY="sekret-do-not-leak-XYZ"
  run bash -c "printf '%s' '${CANARY}' | bash '${SCRIPTS_DIR}/browser-fill.sh' --ref e1 --secret-stdin"
  assert_status 0
  printf '%s' "${output}" | grep -q "${CANARY}" \
    && fail "skill stdout leaked the secret canary: ${CANARY}" || true
  # Reply shape still correct (don't accept a "no output" pass).
  printf '%s' "${output}" | jq -e '.verb == "fill" and .status == "ok"' >/dev/null
}
```

The canary string MUST be:
- **Unique** to this test (so a grep can't accidentally match a real reply field). Embed the verb name and the test number: `sekret-do-not-leak-CDT-1c-ii`, `canary-creds-show-49`.
- **Long enough** that grep's failure mode is meaningful. ~10+ ASCII characters; shorter strings risk colliding with field names like `id` or `ok`.
- **Distinct** from the bytes the test injects elsewhere (don't reuse the canary as a username).

## Why a sentinel beats field-shape assertions

Field-shape assertions catch the regression you predict; sentinels catch the regression you didn't predict. The sentinel test answers a different question:

> "Does **any** code path between stdin-read and stdout-write echo this byte sequence?"

That question is what the AP-7 invariant actually claims. Anchoring the test to a specific field reduces it to "does *this one path* echo," which is the strictly weaker claim.

## Layered coverage: bash AND daemon

Verbs that go through the bridge daemon need **two** canaries:

```
tests/<verb>.bats             # bash-side canary (verb script -> adapter)
tests/<adapter>_daemon_e2e.bats # daemon-side canary (bridge -> daemon -> MCP)
```

Each layer can independently leak — bridge could echo on its way to the daemon, or the daemon could echo back through IPC. The bash-side canary doesn't catch a daemon-side leak and vice versa.

Sample placement (already shipped): `fill --secret-stdin` has a canary in both `tests/browser-fill.bats` (bash) and `tests/chrome-devtools-mcp_daemon_e2e.bats:140` (daemon).

## Don't grep the file system

```
WRONG — assert canary doesn't appear in any state-dir file
grep -r "${CANARY}" "${BROWSER_SKILL_HOME}" && fail "leaked to disk"
```

Some verbs **legitimately persist the secret** (creds-add writes to keychain/file backend; that's the whole point). Disk persistence is governed by the credential-backend test, not by the privacy canary. The privacy canary is exclusively about **stdout** — what the agent / Claude transcript sees.

## Checklist for any new secret-ingesting verb

```
1. Pick a unique canary string (`sekret-do-not-leak-<verb>-<n>`).
2. Pipe the canary in via the verb's --secret-stdin / --*-stdin flag.
3. Capture stdout with `run bash -c '...'` (let bats own the buffer).
4. Negative assert: `printf '%s' "$output" | grep -q "${CANARY}" && fail`.
5. Positive assert: jq the reply shape so a "no output" run doesn't false-pass.
6. If the verb routes through a daemon/bridge, add a SECOND canary at the
   daemon-e2e layer. Each layer's stdout is separately observable.
7. NEVER grep ${BROWSER_SKILL_HOME} for the canary — disk persistence is
   the credential backend's responsibility, not this test's invariant.
```

## See also

- [Anti-patterns: tool extension `AP-7`](anti-patterns-tool-extension.md) — secrets-via-stdin invariant.
- [Body-bytes-not-body recipe](body-bytes-not-body.md) — sister pattern for non-secret caller-supplied content.
- `tests/argv_leak.bats` — the AP-7 enforcement test (catches secrets on argv).
