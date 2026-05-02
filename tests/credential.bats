load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  init_paths
}
teardown() {
  teardown_temp_home
}

# Helper: minimal valid credential metadata JSON.
_meta_json() {
  local name="${1:-prod--admin}" backend="${2:-plaintext}"
  jq -nc --arg n "${name}" --arg b "${backend}" '{
    schema_version: 1,
    name: $n,
    site: ($n | split("--") | .[0]),
    account: "admin@example.com",
    backend: $b,
    auth_flow: "single-step-username-password",
    auto_relogin: true,
    totp_enabled: false,
    created_at: "2026-05-02T12:00:00Z"
  }'
}

run_lib() {
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/credential.sh'
    $*
  "
}

@test "credential.sh: file exists and is readable" {
  [ -f "${LIB_DIR}/credential.sh" ] || fail "lib file missing"
  [ -r "${LIB_DIR}/credential.sh" ] || fail "lib not readable"
}

@test "credential.sh: credential_save writes a 0600 metadata file" {
  meta="$(_meta_json prod--admin)"
  run_lib "credential_save prod--admin '${meta}'"
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.json" ]
  mode="$(file_mode "${BROWSER_SKILL_HOME}/credentials/prod--admin.json")"
  [ "${mode}" = "600" ] || fail "expected mode 600, got ${mode}"
}

@test "credential.sh: credential_save creates CREDENTIALS_DIR mode 700 if missing" {
  meta="$(_meta_json prod--admin)"
  run_lib "credential_save prod--admin '${meta}'"
  mode="$(file_mode "${BROWSER_SKILL_HOME}/credentials")"
  [ "${mode}" = "700" ] || fail "expected mode 700 on dir, got ${mode}"
}

@test "credential.sh: credential_save rejects invalid JSON" {
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_save prod--admin 'not-json'
  "
  [ "${status}" -ne 0 ] || fail "credential_save should reject non-JSON metadata"
}

@test "credential.sh: credential_save rejects metadata missing required fields" {
  bad="$(jq -nc '{name: "prod--admin"}')"  # missing site, account, backend, etc.
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_save prod--admin '${bad}'
  "
  [ "${status}" -ne 0 ] || fail "credential_save should reject metadata missing required fields"
}

@test "credential.sh: credential_save rejects when name already exists (no implicit overwrite)" {
  meta="$(_meta_json prod--admin)"
  run_lib "credential_save prod--admin '${meta}'"
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_save prod--admin '${meta}'
  "
  [ "${status}" -ne 0 ] || fail "credential_save on existing should fail (caller must delete first)"
}

@test "credential.sh: credential_load echoes metadata JSON exactly" {
  meta="$(_meta_json prod--admin)"
  run_lib "credential_save prod--admin '${meta}'"
  out="$(run_lib "credential_load prod--admin")"
  [ "$(printf '%s' "${out}" | jq -r .name)" = "prod--admin" ]
  [ "$(printf '%s' "${out}" | jq -r .backend)" = "plaintext" ]
}

@test "credential.sh: credential_load NEVER includes a 'secret' field (privacy invariant)" {
  meta="$(_meta_json prod--admin)"
  run_lib "credential_save prod--admin '${meta}'"
  printf 'sekret-do-not-leak' | run_lib "credential_set_secret prod--admin"
  out="$(run_lib "credential_load prod--admin")"
  if printf '%s' "${out}" | grep -q 'sekret-do-not-leak'; then
    fail "credential_load output contains the secret value — PRIVACY LEAK"
  fi
  if printf '%s' "${out}" | jq -e 'has("secret")' >/dev/null 2>&1; then
    fail "credential_load output has a 'secret' key — PRIVACY LEAK"
  fi
}

@test "credential.sh: credential_load on missing exits non-zero" {
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_load never-set
  "
  [ "${status}" -ne 0 ] || fail "credential_load on missing should fail"
}

@test "credential.sh: credential_meta_load is alias for credential_load" {
  meta="$(_meta_json prod--admin)"
  run_lib "credential_save prod--admin '${meta}'"
  a="$(run_lib "credential_load prod--admin")"
  b="$(run_lib "credential_meta_load prod--admin")"
  [ "${a}" = "${b}" ] || fail "credential_meta_load output differs from credential_load"
}

@test "credential.sh: credential_exists returns 0/1" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_exists prod--admin
  "
  [ "${status}" = "1" ] || fail "exists on missing should be 1, got ${status}"

  meta="$(_meta_json prod--admin)"
  run_lib "credential_save prod--admin '${meta}'"

  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_exists prod--admin
  "
  [ "${status}" = "0" ] || fail "exists on present should be 0, got ${status}"
}

@test "credential.sh: credential_list_names returns sorted names, excludes .secret files" {
  run_lib "credential_save aaa--x '$(_meta_json aaa--x)'"
  run_lib "credential_save zzz--y '$(_meta_json zzz--y)'"
  printf 'pw-aaa' | run_lib "credential_set_secret aaa--x"
  out="$(run_lib "credential_list_names")"
  expected="$(printf 'aaa--x\nzzz--y')"
  [ "${out}" = "${expected}" ] || fail "expected '${expected}', got '${out}'"
}

@test "credential.sh: credential_set_secret routes to plaintext backend by metadata.backend" {
  meta="$(_meta_json prod--admin plaintext)"
  run_lib "credential_save prod--admin '${meta}'"
  printf 'pw-route' | run_lib "credential_set_secret prod--admin"
  out="$(run_lib "credential_get_secret prod--admin")"
  [ "${out}" = "pw-route" ]
}

@test "credential.sh: credential_set_secret + get_secret roundtrip via keychain backend (stub-validated)" {
  KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
  export KEYCHAIN_STUB_STORE KEYCHAIN_SECURITY_BIN
  meta="$(_meta_json prod--admin keychain)"
  run_lib "credential_save prod--admin '${meta}'"
  printf 'pw-keychain' | KEYCHAIN_STUB_STORE="${KEYCHAIN_STUB_STORE}" KEYCHAIN_SECURITY_BIN="${KEYCHAIN_SECURITY_BIN}" run_lib "credential_set_secret prod--admin"
  out="$(KEYCHAIN_STUB_STORE="${KEYCHAIN_STUB_STORE}" KEYCHAIN_SECURITY_BIN="${KEYCHAIN_SECURITY_BIN}" run_lib "credential_get_secret prod--admin")"
  [ "${out}" = "pw-keychain" ] || fail "expected 'pw-keychain', got '${out}'"
}

@test "credential.sh: credential_set_secret returns EXIT_TOOL_MISSING for libsecret backend (deferred to part 2c)" {
  meta="$(_meta_json prod--admin libsecret)"
  run_lib "credential_save prod--admin '${meta}'"
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    printf 'pw' | credential_set_secret prod--admin
  "
  [ "${status}" = "21" ] || fail "expected EXIT_TOOL_MISSING (21) for deferred libsecret backend, got ${status}"
}

@test "credential.sh: credential_set_secret rejects unknown backend" {
  bad_meta="$(jq -nc '{
    schema_version:1, name:"prod--x", site:"prod", account:"a@b.c",
    backend:"made-up-vault", auth_flow:"single-step-username-password",
    auto_relogin:true, totp_enabled:false, created_at:"2026-05-02T12:00:00Z"
  }')"
  run_lib "credential_save prod--x '${bad_meta}'"
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    printf 'pw' | credential_set_secret prod--x
  "
  [ "${status}" = "2" ] || fail "expected EXIT_USAGE_ERROR (2) for unknown backend, got ${status}"
}

@test "credential.sh: credential_set_secret errors clearly when metadata is missing" {
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    printf 'pw' | credential_set_secret never-saved
  "
  [ "${status}" -ne 0 ] || fail "credential_set_secret on missing metadata should fail"
}

@test "credential.sh: credential_delete removes both metadata and secret" {
  meta="$(_meta_json prod--admin)"
  run_lib "credential_save prod--admin '${meta}'"
  printf 'pw' | run_lib "credential_set_secret prod--admin"
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.json" ]
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret" ]
  run_lib "credential_delete prod--admin"
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.json" ]
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret" ]
}

@test "credential.sh: credential_delete is idempotent" {
  run_lib "credential_delete never-set"
}

@test "credential.sh: assert_safe_name rejects path traversal in credential_save" {
  meta="$(_meta_json '../escape')"
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_save '../escape' '${meta}'
  "
  [ "${status}" -ne 0 ] || fail "credential_save with '../escape' should fail"
}

@test "credential.sh: schema_version pinned to 1 (single source of truth for migrations)" {
  result="$(bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    printf '%s' \"\${BROWSER_SKILL_CREDENTIAL_SCHEMA_VERSION}\"
  ")"
  [ "${result}" = "1" ] || fail "expected schema_version 1, got '${result}'"
}
