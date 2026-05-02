# scripts/lib/secret/libsecret.sh — Linux libsecret credentials backend.
#
# Implements the 4-fn secret backend contract used by lib/credential.sh:
#   secret_set NAME       (stdin → libsecret via `secret-tool store`)
#   secret_get NAME       (libsecret → stdout via `secret-tool lookup`)
#   secret_delete NAME    (idempotent rm via `secret-tool clear`)
#   secret_exists NAME    (probe via `secret-tool lookup` to /dev/null)
#
# All entries share a single service attribute:
#   ${BROWSER_SKILL_LIBSECRET_SERVICE:-browser-skill}
# Per-credential entries use account = NAME.
#
# AP-7 status: CLEAN — no documented exception. The upstream `secret-tool`
# CLI reads the password from stdin natively (via the `store` subcommand).
# `secret_set` reads stdin and pipes directly into `secret-tool store`;
# the password never appears in argv. Contrast with the macOS keychain
# backend (`scripts/lib/secret/keychain.sh`) which has a documented AP-7
# exception because the upstream `security` CLI is argv-only.
#
# Stdin verbatim: `secret-tool store` reads the password from stdin without
# trailing-newline strip — what you pipe in is what gets stored. Tests
# assert byte-exact roundtrip. If you `printf 'pw\n' | secret_set foo`,
# the stored value is `pw\n` (with newline). For most callers,
# `printf 'pw' | secret_set foo` (no trailing newline) is the right idiom.

[ -n "${BROWSER_SKILL_SECRET_LIBSECRET_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SECRET_LIBSECRET_LOADED=1

readonly _LIBSECRET_SERVICE="${BROWSER_SKILL_LIBSECRET_SERVICE:-browser-skill}"
readonly _LIBSECRET_TOOL_BIN="${LIBSECRET_TOOL_BIN:-secret-tool}"

# secret_set NAME — stdin → libsecret via `secret-tool store`. AP-7 clean.
# Idempotency: clear-then-store. `clear` exits non-zero on missing item;
# the swallow keeps the contract.
secret_set() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_LIBSECRET_TOOL_BIN}" clear \
    service "${_LIBSECRET_SERVICE}" account "${name}" \
    >/dev/null 2>&1 || true
  "${_LIBSECRET_TOOL_BIN}" store \
    --label "browser-skill: ${name}" \
    service "${_LIBSECRET_SERVICE}" account "${name}"
}

# secret_get NAME — echoes the password to stdout. Exits non-zero (1) if
# entry not in libsecret.
secret_get() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_LIBSECRET_TOOL_BIN}" lookup \
    service "${_LIBSECRET_SERVICE}" account "${name}"
}

# secret_delete NAME — idempotent. `secret-tool clear` exits non-zero on
# missing items; the `|| true` swallow makes the contract match the
# plaintext + keychain backends.
secret_delete() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_LIBSECRET_TOOL_BIN}" clear \
    service "${_LIBSECRET_SERVICE}" account "${name}" \
    >/dev/null 2>&1 || true
}

# secret_exists NAME — returns 0 if entry present in libsecret, non-zero
# if not. Probes via `secret-tool lookup` discarding the password.
secret_exists() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_LIBSECRET_TOOL_BIN}" lookup \
    service "${_LIBSECRET_SERVICE}" account "${name}" \
    >/dev/null 2>&1
}
