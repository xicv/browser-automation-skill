# scripts/lib/secret/keychain.sh — macOS Keychain credentials backend.
#
# Implements the 4-fn secret backend contract used by lib/credential.sh:
#   secret_set NAME       (stdin → keychain via `security add-generic-password`)
#   secret_get NAME       (keychain → stdout via `security find-generic-password -w`)
#   secret_delete NAME    (idempotent rm via `security delete-generic-password`)
#   secret_exists NAME    (probe via `security find-generic-password` no -w)
#
# All entries share a single keychain service prefix:
#   ${BROWSER_SKILL_KEYCHAIN_SERVICE:-browser-skill}
# Per-credential entries use account = NAME.
#
# AP-7 documented exception:
# The macOS `security` CLI takes the password on argv via `-w PASSWORD`. There
# is no clean stdin-input path in the upstream tool — the only stdin alternative
# is an interactive TTY prompt which doesn't compose with non-TTY pipelines.
# Working around this would require either:
#   - A python+keyring runtime dep (rejected: adds an external dep for one OS)
#   - A compiled Swift/ObjC helper binary (rejected: adds build step)
#   - osascript-mediated Keychain Services API (rejected: secrets via osascript
#     -e are also argv-visible)
# The skill's own code never puts secrets on argv (`secret_set` reads stdin and
# constructs the `security` invocation locally). The leak surface is the brief
# `security` subprocess (~50ms wall-clock). Mitigations:
#   1. Subprocess is short-lived; ps polling at any practical rate misses it.
#   2. The -U flag makes the call idempotent (no second invocation needed).
#   3. Linux libsecret backend (phase-05 part 2c) uses `secret-tool` which IS
#      stdin-clean — the AP-7 exception stays macOS-specific.
# This is the "honest documented exception" pattern: AP-7 is the invariant for
# our code; the upstream tool's argv-only design is an unavoidable upstream
# constraint we acknowledge in this header + the cheatsheet (when 2d ships)
# rather than work around with extra runtime deps.

[ -n "${BROWSER_SKILL_SECRET_KEYCHAIN_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SECRET_KEYCHAIN_LOADED=1

readonly _KEYCHAIN_SERVICE="${BROWSER_SKILL_KEYCHAIN_SERVICE:-browser-skill}"
readonly _KEYCHAIN_SECURITY_BIN="${KEYCHAIN_SECURITY_BIN:-security}"

# secret_set NAME — stdin → keychain via `security add-generic-password -w`.
# The -U flag makes the call idempotent: if an entry already exists for
# (-s SERVICE -a NAME), it is updated rather than rejected with an error.
secret_set() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  local secret
  secret="$(cat)"
  "${_KEYCHAIN_SECURITY_BIN}" add-generic-password \
    -s "${_KEYCHAIN_SERVICE}" \
    -a "${name}" \
    -w "${secret}" \
    -U \
    >/dev/null
}

# secret_get NAME — echoes the password to stdout via `security find-generic-
# password -w`. Exits non-zero if entry is not in the keychain (security's
# native exit-44, "item could not be found").
secret_get() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_KEYCHAIN_SECURITY_BIN}" find-generic-password \
    -s "${_KEYCHAIN_SERVICE}" \
    -a "${name}" \
    -w \
    2>/dev/null
}

# secret_delete NAME — idempotent. `security delete-generic-password` exits
# non-zero on missing items; the `|| true` swallow makes the contract match
# the plaintext backend (and what callers expect).
secret_delete() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_KEYCHAIN_SECURITY_BIN}" delete-generic-password \
    -s "${_KEYCHAIN_SERVICE}" \
    -a "${name}" \
    >/dev/null 2>&1 || true
}

# secret_exists NAME — returns 0 if entry present in keychain, non-zero if not.
# Probes via `security find-generic-password` without -w (no payload echo,
# just existence check).
secret_exists() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_KEYCHAIN_SECURITY_BIN}" find-generic-password \
    -s "${_KEYCHAIN_SERVICE}" \
    -a "${name}" \
    >/dev/null 2>&1
}
