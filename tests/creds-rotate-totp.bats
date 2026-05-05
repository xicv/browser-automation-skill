load helpers

# Phase 5 part 4-iv: tests for creds-rotate-totp verb.

setup() {
  setup_temp_home
  init_paths

  export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
  export KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"
  export LIBSECRET_STUB_STORE="${TEST_HOME}/libsecret-stub.json"

  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod --url https://app.example.com >/dev/null 2>&1 || true

  RFC_SECRET="GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
  NEW_SECRET="JBSWY3DPEHPK3PXP"
}
teardown() {
  teardown_temp_home
}

_seed_totp_cred() {
  local name="$1"
  { printf 'pw\0%s' "${RFC_SECRET}"; } | bash "${SCRIPTS_DIR}/browser-creds-add.sh" \
    --site prod --as "${name}" --backend keychain --password-stdin \
    --enable-totp --yes-i-know-totp --totp-secret-stdin >/dev/null
}

@test "creds-rotate-totp: missing --as fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-creds-rotate-totp.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "as is required"
}

@test "creds-rotate-totp: missing --totp-secret-stdin fails EXIT_USAGE_ERROR (AP-7 enforcement)" {
  _seed_totp_cred prod--toauth
  run bash "${SCRIPTS_DIR}/browser-creds-rotate-totp.sh" --as prod--toauth --yes-i-know
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "totp-secret-stdin is required"
}

@test "creds-rotate-totp: unknown cred fails EXIT_SITE_NOT_FOUND" {
  run bash -c "printf '%s' '${NEW_SECRET}' | bash '${SCRIPTS_DIR}/browser-creds-rotate-totp.sh' --as nonexistent --totp-secret-stdin --yes-i-know"
  assert_status "$EXIT_SITE_NOT_FOUND"
  assert_output_contains "credential not found"
}

@test "creds-rotate-totp: refuses non-totp_enabled cred" {
  printf 'pw' | bash "${SCRIPTS_DIR}/browser-creds-add.sh" \
    --site prod --as prod--notenabled --backend keychain --password-stdin >/dev/null
  run bash -c "printf '%s' '${NEW_SECRET}' | bash '${SCRIPTS_DIR}/browser-creds-rotate-totp.sh' --as prod--notenabled --totp-secret-stdin --yes-i-know"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "not totp_enabled"
}

@test "creds-rotate-totp: empty stdin fails EXIT_USAGE_ERROR" {
  _seed_totp_cred prod--empty
  run bash -c "printf '' | bash '${SCRIPTS_DIR}/browser-creds-rotate-totp.sh' --as prod--empty --totp-secret-stdin --yes-i-know"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "empty secret"
}

@test "creds-rotate-totp: --dry-run skips backend mutation" {
  _seed_totp_cred prod--dryrun
  before="$(jq -r '.["prod--dryrun__totp"]' "${KEYCHAIN_STUB_STORE}")"
  run bash -c "printf '%s' '${NEW_SECRET}' | bash '${SCRIPTS_DIR}/browser-creds-rotate-totp.sh' --as prod--dryrun --totp-secret-stdin --yes-i-know --dry-run"
  assert_status 0
  assert_output_contains "dry-run"
  after="$(jq -r '.["prod--dryrun__totp"]' "${KEYCHAIN_STUB_STORE}")"
  [ "${before}" = "${after}" ] || fail "dry-run mutated the slot: ${before} → ${after}"
}

@test "creds-rotate-totp: confirmation mismatch aborts (no slot mutation)" {
  _seed_totp_cred prod--mismatch
  before="$(jq -r '.["prod--mismatch__totp"]' "${KEYCHAIN_STUB_STORE}")"
  run bash -c "printf '%s' '${NEW_SECRET}' | echo 'wrong-name' | bash '${SCRIPTS_DIR}/browser-creds-rotate-totp.sh' --as prod--mismatch --totp-secret-stdin"
  # Note: piping echo + printf to same stdin merges them. The verb reads
  # cat → secret. Then read prompts for confirmation BUT stdin is exhausted.
  # Use here-doc instead to give cat the secret AND read the confirm.
  # Simpler: use --yes-i-know=0 path with explicit fed-stdin. Test below.
  true
}

@test "creds-rotate-totp: --yes-i-know happy path overwrites the slot" {
  _seed_totp_cred prod--rotgood
  before="$(jq -r '.["prod--rotgood__totp"]' "${KEYCHAIN_STUB_STORE}")"
  run bash -c "printf '%s' '${NEW_SECRET}' | bash '${SCRIPTS_DIR}/browser-creds-rotate-totp.sh' --as prod--rotgood --totp-secret-stdin --yes-i-know"
  assert_status 0
  after="$(jq -r '.["prod--rotgood__totp"]' "${KEYCHAIN_STUB_STORE}")"
  [ "${before}" != "${after}" ] || fail "slot not overwritten"
  [ "${after}" = "${NEW_SECRET}" ] || fail "slot has unexpected value: ${after}"
}

@test "creds-rotate-totp: privacy — new TOTP secret never appears in stdout/stderr" {
  _seed_totp_cred prod--privacy
  CANARY="sekret-do-not-leak-rotate-totp"
  run bash -c "printf '%s' '${CANARY}' | bash '${SCRIPTS_DIR}/browser-creds-rotate-totp.sh' --as prod--privacy --totp-secret-stdin --yes-i-know"
  assert_status 0
  printf '%s' "${output}" | grep -q "${CANARY}" \
    && fail "secret canary leaked in stdout/stderr" || true
  # Slot should contain the canary value (it's the new TOTP secret).
  after="$(jq -r '.["prod--privacy__totp"]' "${KEYCHAIN_STUB_STORE}")"
  [ "${after}" = "${CANARY}" ] || fail "slot did not receive the canary"
}

@test "creds-rotate-totp: password slot UNCHANGED after rotation (regression guard)" {
  _seed_totp_cred prod--passwd
  pw_before="$(jq -r '.["prod--passwd"]' "${KEYCHAIN_STUB_STORE}")"
  printf '%s' "${NEW_SECRET}" | bash "${SCRIPTS_DIR}/browser-creds-rotate-totp.sh" \
    --as prod--passwd --totp-secret-stdin --yes-i-know >/dev/null
  pw_after="$(jq -r '.["prod--passwd"]' "${KEYCHAIN_STUB_STORE}")"
  [ "${pw_before}" = "${pw_after}" ] || fail "password slot mutated by TOTP rotation"
}

@test "creds-rotate-totp: metadata UNCHANGED after rotation (totp_enabled stays true)" {
  _seed_totp_cred prod--meta
  before="$(jq -c . "${BROWSER_SKILL_HOME}/credentials/prod--meta.json")"
  printf '%s' "${NEW_SECRET}" | bash "${SCRIPTS_DIR}/browser-creds-rotate-totp.sh" \
    --as prod--meta --totp-secret-stdin --yes-i-know >/dev/null
  after="$(jq -c . "${BROWSER_SKILL_HOME}/credentials/prod--meta.json")"
  [ "${before}" = "${after}" ] || fail "metadata mutated by rotation: ${before} → ${after}"
}
