load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  init_paths

  # Per-test isolated stub state — keeps tests order-independent.
  KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  STUB_LOG_FILE="${TEST_HOME}/security-stub.log"
  export KEYCHAIN_STUB_STORE STUB_LOG_FILE
  export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
}
teardown() {
  teardown_temp_home
}

run_backend() {
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/secret/keychain.sh'
    $*
  "
}

@test "secret/keychain.sh: file exists and is readable" {
  [ -f "${LIB_DIR}/secret/keychain.sh" ] || fail "backend file missing"
  [ -r "${LIB_DIR}/secret/keychain.sh" ] || fail "backend not readable"
}

@test "secret/keychain.sh: AP-7 documented exception is present in header (acknowledges argv leak)" {
  if ! grep -qE 'AP-7' "${LIB_DIR}/secret/keychain.sh"; then
    fail "keychain.sh header MUST cite AP-7 — see plan §AP-7-caveat"
  fi
  if ! grep -qiE 'documented exception|documented' "${LIB_DIR}/secret/keychain.sh"; then
    fail "keychain.sh header MUST cite the AP-7 exception explicitly"
  fi
}

@test "secret/keychain.sh: secret_set reads stdin and persists to keychain (via stub)" {
  printf 'pw-roundtrip' | run_backend "secret_set foo"
  val="$(jq -r '.foo' "${KEYCHAIN_STUB_STORE}")"
  [ "${val}" = "pw-roundtrip" ] || fail "expected 'pw-roundtrip' in stub store, got '${val}'"
}

@test "secret/keychain.sh: secret_get echoes the payload verbatim" {
  printf 'pw-verbatim' | run_backend "secret_set foo"
  out="$(run_backend "secret_get foo")"
  [ "${out}" = "pw-verbatim" ] || fail "expected 'pw-verbatim', got '${out}'"
}

@test "secret/keychain.sh: secret_delete removes the entry" {
  printf 'pw' | run_backend "secret_set foo"
  run_backend "secret_delete foo"
  val="$(jq -r '.foo // ""' "${KEYCHAIN_STUB_STORE}")"
  [ -z "${val}" ] || fail "entry should be deleted, but found '${val}'"
}

@test "secret/keychain.sh: secret_delete is idempotent (no-op on missing)" {
  run_backend "secret_delete never-set"
}

@test "secret/keychain.sh: secret_exists returns 0 if present, non-zero if not" {
  run bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/secret/keychain.sh'
    secret_exists foo
  "
  [ "${status}" -ne 0 ] || fail "secret_exists on missing should be non-zero (got ${status})"

  printf 'pw' | run_backend "secret_set foo"
  run bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/secret/keychain.sh'
    secret_exists foo
  "
  [ "${status}" = "0" ] || fail "secret_exists on present should be 0 (got ${status})"
}

@test "secret/keychain.sh: assert_safe_name rejects path traversal" {
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/secret/keychain.sh'
    printf 'pw' | secret_set '../escape'
  "
  [ "${status}" -ne 0 ] || fail "secret_set with '../escape' should fail"
}

@test "secret/keychain.sh: multiple secrets coexist independently" {
  printf 'alpha' | run_backend "secret_set foo"
  printf 'beta'  | run_backend "secret_set bar"
  out_foo="$(run_backend "secret_get foo")"
  out_bar="$(run_backend "secret_get bar")"
  [ "${out_foo}" = "alpha" ]
  [ "${out_bar}" = "beta" ]
}

@test "secret/keychain.sh: last-write-wins on overwrite" {
  printf 'old' | run_backend "secret_set foo"
  printf 'new' | run_backend "secret_set foo"
  out="$(run_backend "secret_get foo")"
  [ "${out}" = "new" ]
}

@test "secret/keychain.sh: secret_get on missing exits non-zero" {
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/secret/keychain.sh'
    secret_get never-set
  "
  [ "${status}" -ne 0 ] || fail "secret_get on missing should fail"
}

@test "secret/keychain.sh: default service prefix is 'browser-skill' (visible in stub log)" {
  printf 'pw' | run_backend "secret_set foo"
  if ! grep -q '^browser-skill$' "${STUB_LOG_FILE}"; then
    fail "expected service prefix 'browser-skill' in stub log; log:\n$(cat "${STUB_LOG_FILE}")"
  fi
}

@test "secret/keychain.sh: BROWSER_SKILL_KEYCHAIN_SERVICE override is honored" {
  printf 'pw' | BROWSER_SKILL_KEYCHAIN_SERVICE=custom-prefix run_backend "secret_set foo"
  if ! grep -q '^custom-prefix$' "${STUB_LOG_FILE}"; then
    fail "expected custom service prefix in stub log"
  fi
}
