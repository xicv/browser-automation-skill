load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  init_paths

  # Defensive: stubs unconditionally — no real OS vault risk.
  export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
  export KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"
  export LIBSECRET_STUB_STORE="${TEST_HOME}/libsecret-stub.json"
}
teardown() { teardown_temp_home; }

_seed_full() {
  # Save metadata + payload via the full credential dispatcher (so backend-
  # specific writes happen). NAME, BACKEND, SECRET.
  local name="$1" backend="$2" secret="$3"
  local meta
  meta="$(jq -nc --arg n "${name}" --arg b "${backend}" \
    '{schema_version:1, name:$n, site:"prod", account:"a@b.c", backend:$b,
      auth_flow:"single-step-username-password",
      auto_relogin:true, totp_enabled:false, created_at:"2026-05-03T00:00:00Z"}')"
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_save '${name}' '${meta}'
    printf '%s' '${secret}' | credential_set_secret '${name}'
  "
}

@test "creds-remove: file exists and is executable" {
  [ -f "${SCRIPTS_DIR}/browser-creds-remove.sh" ] || fail "verb missing"
  [ -x "${SCRIPTS_DIR}/browser-creds-remove.sh" ] || fail "verb not executable"
}

@test "creds-remove: --yes-i-know skips prompt and deletes (plaintext backend)" {
  _seed_full prod--admin plaintext pw
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.json" ]
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret" ]
  bash "${SCRIPTS_DIR}/browser-creds-remove.sh" --as prod--admin --yes-i-know
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.json" ] || fail "metadata still present"
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret" ] || fail "secret still present"
}

@test "creds-remove: typed-name confirmation accepts exact match" {
  _seed_full prod--admin plaintext pw
  printf 'prod--admin\n' | bash "${SCRIPTS_DIR}/browser-creds-remove.sh" --as prod--admin
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.json" ] || fail "should have been removed"
}

@test "creds-remove: typed-name mismatch refuses (exit 2)" {
  _seed_full prod--admin plaintext pw
  run bash -c "printf 'wrong\n' | bash '${SCRIPTS_DIR}/browser-creds-remove.sh' --as prod--admin"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.json" ] || fail "metadata should still exist after refusal"
}

@test "creds-remove: --dry-run reports planned action and removes nothing" {
  _seed_full prod--admin plaintext pw
  out="$(bash "${SCRIPTS_DIR}/browser-creds-remove.sh" --as prod--admin --dry-run)"
  printf '%s' "${out}" | jq -e '.would_run == true' >/dev/null
  printf '%s' "${out}" | jq -e '.why == "dry-run"' >/dev/null
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.json" ] || fail "metadata removed despite --dry-run"
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret" ] || fail "secret removed despite --dry-run"
}

@test "creds-remove: missing credential exits non-zero" {
  run bash "${SCRIPTS_DIR}/browser-creds-remove.sh" --as never-set --yes-i-know
  [ "${status}" -ne 0 ] || fail "expected non-zero on missing credential"
}

@test "creds-remove: --as is required (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-creds-remove.sh" --yes-i-know
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
}

@test "creds-remove: keychain backend — entry gone in stub store after removal" {
  _seed_full prod--keychain keychain pw-keychain
  val="$(jq -r '."prod--keychain"' "${KEYCHAIN_STUB_STORE}")"
  [ "${val}" = "pw-keychain" ] || fail "seed failed; got '${val}'"
  bash "${SCRIPTS_DIR}/browser-creds-remove.sh" --as prod--keychain --yes-i-know
  val="$(jq -r '."prod--keychain" // "GONE"' "${KEYCHAIN_STUB_STORE}")"
  [ "${val}" = "GONE" ] || fail "keychain entry should be gone, got '${val}'"
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/prod--keychain.json" ] || fail "metadata should be gone"
}

@test "creds-remove: libsecret backend — entry gone in stub store after removal" {
  _seed_full prod--libsec libsecret pw-libsecret
  val="$(jq -r '."prod--libsec"' "${LIBSECRET_STUB_STORE}")"
  [ "${val}" = "pw-libsecret" ] || fail "seed failed; got '${val}'"
  bash "${SCRIPTS_DIR}/browser-creds-remove.sh" --as prod--libsec --yes-i-know
  val="$(jq -r '."prod--libsec" // "GONE"' "${LIBSECRET_STUB_STORE}")"
  [ "${val}" = "GONE" ] || fail "libsecret entry should be gone, got '${val}'"
}

@test "creds-remove: summary JSON has required keys" {
  _seed_full prod--admin plaintext pw
  out="$(bash "${SCRIPTS_DIR}/browser-creds-remove.sh" --as prod--admin --yes-i-know 2>/dev/null)"
  summary="$(printf '%s\n' "${out}" | tail -1)"
  printf '%s' "${summary}" | jq -e '.verb == "creds-remove"' >/dev/null
  printf '%s' "${summary}" | jq -e '.status == "ok"' >/dev/null
  printf '%s' "${summary}" | jq -e '.why == "delete"' >/dev/null
  printf '%s' "${summary}" | jq -e 'has("credential") and has("duration_ms")' >/dev/null
}
