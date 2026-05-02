# scripts/lib/secret/plaintext.sh — plaintext credentials backend.
#
# Implements the 4-fn secret backend contract used by lib/credential.sh:
#   secret_set NAME       (stdin → ${CREDENTIALS_DIR}/<name>.secret mode 0600)
#   secret_get NAME       (file → stdout)
#   secret_delete NAME    (rm -f, idempotent)
#   secret_exists NAME    (returns 0 if present, 1 if not)
#
# Backends are dumb I/O — they DO NOT enforce any flow logic (typed-phrase
# confirmation, --reveal masking, etc). All flow concerns live in
# lib/credential.sh and the verb scripts (Phase 5 part 2d).
#
# AP-7: secrets MUST flow via stdin pipes only. NEVER as positional argv.
# tests/secret_plaintext.bats greps this file for the anti-pattern.
#
# Sibling backends (deferred):
#   - scripts/lib/secret/keychain.sh (macOS Security framework) — phase-05 part 2b
#   - scripts/lib/secret/libsecret.sh (Linux Secret Service)    — phase-05 part 2c
#
# Plaintext threat model: file mode 0600 + ${BROWSER_SKILL_HOME} mode 0700 +
# disk encryption (FileVault on macOS / LUKS on Linux — doctor advises). A
# user without disk encryption is warned by `doctor` (Phase 1). The verb
# layer (part 2d's `creds add`) requires a typed-phrase confirmation on
# first plaintext use. None of that policy lives here.

[ -n "${BROWSER_SKILL_SECRET_PLAINTEXT_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SECRET_PLAINTEXT_LOADED=1

_secret_plaintext_path() {
  printf '%s/%s.secret' "${CREDENTIALS_DIR}" "$1"
}

# secret_set NAME — reads stdin, writes ${CREDENTIALS_DIR}/<name>.secret 0600.
# Atomically: writes to a tmp file then renames. Overwrites existing payload.
secret_set() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"

  mkdir -p "${CREDENTIALS_DIR}"
  chmod 700 "${CREDENTIALS_DIR}"

  local path tmp
  path="$(_secret_plaintext_path "${name}")"
  tmp="${path}.tmp.$$"

  ( umask 077; cat > "${tmp}" )
  chmod 600 "${tmp}"
  mv "${tmp}" "${path}"
}

# secret_get NAME — echoes the payload to stdout. Exits non-zero on missing.
secret_get() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  local path
  path="$(_secret_plaintext_path "${name}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_USAGE_ERROR}" "secret not found: ${name}"
  fi
  cat "${path}"
}

# secret_delete NAME — idempotent rm -f.
secret_delete() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  rm -f "$(_secret_plaintext_path "${name}")"
}

# secret_exists NAME — returns 0 if present, 1 if not.
secret_exists() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  [ -f "$(_secret_plaintext_path "${name}")" ]
}
