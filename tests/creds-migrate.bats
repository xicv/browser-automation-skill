load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  init_paths

  # Defensive: stubs for keychain + libsecret. Same lesson as part 2b.
  export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
  export KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"
  export LIBSECRET_STUB_STORE="${TEST_HOME}/libsecret-stub.json"

  # Pre-create plaintext marker so seeded plaintext credentials don't hit
  # the first-use gate. Tests that exercise the gate flow remove it.
  mkdir -p "${BROWSER_SKILL_HOME}/credentials"
  chmod 700 "${BROWSER_SKILL_HOME}/credentials"
  : > "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
  chmod 600 "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
}
teardown() { teardown_temp_home; }

_seed_full() {
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

@test "creds-migrate: file exists and is executable" {
  [ -f "${SCRIPTS_DIR}/browser-creds-migrate.sh" ] || fail "verb missing"
  [ -x "${SCRIPTS_DIR}/browser-creds-migrate.sh" ] || fail "verb not executable"
}

@test "creds-migrate: plaintext → keychain (happy path)" {
  _seed_full prod--admin plaintext "pw-migrate-1"
  bash "${SCRIPTS_DIR}/browser-creds-migrate.sh" --as prod--admin --to keychain --yes-i-know
  # Plaintext gone, keychain has it
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret" ] || fail "plaintext .secret should be removed"
  val="$(jq -r '."prod--admin"' "${KEYCHAIN_STUB_STORE}")"
  [ "${val}" = "pw-migrate-1" ] || fail "expected 'pw-migrate-1' in keychain stub, got '${val}'"
  backend="$(jq -r .backend "${BROWSER_SKILL_HOME}/credentials/prod--admin.json")"
  [ "${backend}" = "keychain" ] || fail "metadata.backend should be 'keychain', got '${backend}'"
}

@test "creds-migrate: keychain → libsecret (cross-OS-vault)" {
  _seed_full prod--svc keychain "pw-vault-cross"
  bash "${SCRIPTS_DIR}/browser-creds-migrate.sh" --as prod--svc --to libsecret --yes-i-know
  val_kc="$(jq -r '."prod--svc" // "GONE"' "${KEYCHAIN_STUB_STORE}")"
  val_ls="$(jq -r '."prod--svc"' "${LIBSECRET_STUB_STORE}")"
  [ "${val_kc}" = "GONE" ] || fail "keychain entry should be removed"
  [ "${val_ls}" = "pw-vault-cross" ] || fail "libsecret should have the secret"
}

@test "creds-migrate: libsecret → plaintext requires --yes-i-know-plaintext when marker missing" {
  _seed_full prod--ls libsecret "pw-back-to-plain"
  rm -f "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
  run bash "${SCRIPTS_DIR}/browser-creds-migrate.sh" --as prod--ls --to plaintext --yes-i-know
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR (2), got ${status}"
  printf '%s' "${output}" | grep -q "yes-i-know-plaintext" || fail "error must mention --yes-i-know-plaintext"
  # Original intact
  val="$(jq -r '."prod--ls"' "${LIBSECRET_STUB_STORE}")"
  [ "${val}" = "pw-back-to-plain" ] || fail "original libsecret entry should be intact after refusal"
}

@test "creds-migrate: libsecret → plaintext succeeds with --yes-i-know-plaintext" {
  _seed_full prod--ls libsecret "pw-back-to-plain"
  rm -f "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
  bash "${SCRIPTS_DIR}/browser-creds-migrate.sh" --as prod--ls --to plaintext --yes-i-know --yes-i-know-plaintext
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--ls.secret" ] || fail ".secret file should be created"
  out="$(cat "${BROWSER_SKILL_HOME}/credentials/prod--ls.secret")"
  [ "${out}" = "pw-back-to-plain" ] || fail "expected 'pw-back-to-plain', got '${out}'"
  # Marker should now be created
  [ -f "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged" ] || fail "marker should be created after successful migrate-to-plaintext"
}

@test "creds-migrate: same-backend refusal (exit 2)" {
  _seed_full prod--admin plaintext pw
  run bash "${SCRIPTS_DIR}/browser-creds-migrate.sh" --as prod--admin --to plaintext --yes-i-know
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR (2), got ${status}"
}

@test "creds-migrate: unknown credential (exit 23)" {
  run bash "${SCRIPTS_DIR}/browser-creds-migrate.sh" --as never-set --to keychain --yes-i-know
  [ "${status}" = "${EXIT_SITE_NOT_FOUND}" ] || fail "expected EXIT_SITE_NOT_FOUND (23), got ${status}"
}

@test "creds-migrate: unknown target backend (exit 2)" {
  _seed_full prod--admin plaintext pw
  run bash "${SCRIPTS_DIR}/browser-creds-migrate.sh" --as prod--admin --to made-up-vault --yes-i-know
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR (2), got ${status}"
}

@test "creds-migrate: typed-name mismatch refuses" {
  _seed_full prod--admin plaintext pw
  run bash -c "printf 'wrong\n' | bash '${SCRIPTS_DIR}/browser-creds-migrate.sh' --as prod--admin --to keychain"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR (2), got ${status}"
  # Original intact
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret" ] || fail "original plaintext .secret should be intact"
}

@test "creds-migrate: --dry-run reports without writing" {
  _seed_full prod--admin plaintext pw
  out="$(bash "${SCRIPTS_DIR}/browser-creds-migrate.sh" --as prod--admin --to keychain --yes-i-know --dry-run)"
  printf '%s' "${out}" | jq -e '.would_run == true' >/dev/null
  printf '%s' "${out}" | jq -e '.from == "plaintext"' >/dev/null
  printf '%s' "${out}" | jq -e '.to == "keychain"' >/dev/null
  # Original intact
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret" ] || fail "secret moved despite --dry-run"
  backend="$(jq -r .backend "${BROWSER_SKILL_HOME}/credentials/prod--admin.json")"
  [ "${backend}" = "plaintext" ] || fail "metadata.backend changed despite --dry-run"
}

@test "creds-migrate: summary JSON has required keys + privacy canary" {
  _seed_full prod--canary plaintext "sekret-do-not-leak-migrate"
  out="$(bash "${SCRIPTS_DIR}/browser-creds-migrate.sh" --as prod--canary --to keychain --yes-i-know 2>/dev/null)"
  summary="$(printf '%s\n' "${out}" | tail -1)"
  printf '%s' "${summary}" | jq -e '.verb == "creds-migrate"' >/dev/null
  printf '%s' "${summary}" | jq -e '.status == "ok"' >/dev/null
  printf '%s' "${summary}" | jq -e '.from == "plaintext" and .to == "keychain"' >/dev/null
  printf '%s' "${summary}" | jq -e 'has("credential") and has("duration_ms") and has("why")' >/dev/null
  # PRIVACY: secret value must NOT appear anywhere in the output.
  if printf '%s' "${out}" | grep -q "sekret-do-not-leak-migrate"; then
    fail "creds-migrate output contains the secret value — PRIVACY LEAK"
  fi
}
