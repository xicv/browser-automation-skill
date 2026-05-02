load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  init_paths

  LIBSECRET_STUB_STORE="${TEST_HOME}/libsecret-stub.json"
  STUB_LOG_FILE="${TEST_HOME}/secret-tool-stub.log"
  export LIBSECRET_STUB_STORE STUB_LOG_FILE
  export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"
}
teardown() {
  teardown_temp_home
}

run_backend() {
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/secret/libsecret.sh'
    $*
  "
}

@test "secret/libsecret.sh: file exists and is readable" {
  [ -f "${LIB_DIR}/secret/libsecret.sh" ] || fail "backend file missing"
  [ -r "${LIB_DIR}/secret/libsecret.sh" ] || fail "backend not readable"
}

@test "secret/libsecret.sh: AP-7 clean — header DOES NOT cite a documented exception (opposite of keychain)" {
  if grep -qi 'AP-7 documented exception' "${LIB_DIR}/secret/libsecret.sh"; then
    fail "libsecret backend should NOT cite an AP-7 documented exception — secret-tool reads stdin natively (clean)"
  fi
  # Should affirmatively note stdin-clean property in header.
  if ! grep -qiE 'stdin-clean|stdin clean|reads .* from stdin' "${LIB_DIR}/secret/libsecret.sh"; then
    fail "libsecret backend header should affirm stdin-clean property (AP-7 holds)"
  fi
}

@test "secret/libsecret.sh: secret_set reads stdin and persists (via stub)" {
  printf 'pw-roundtrip' | run_backend "secret_set foo"
  val="$(jq -r '.foo' "${LIBSECRET_STUB_STORE}")"
  [ "${val}" = "pw-roundtrip" ] || fail "expected 'pw-roundtrip' in stub store, got '${val}'"
}

@test "secret/libsecret.sh: secret_get echoes the payload verbatim" {
  printf 'pw-verbatim' | run_backend "secret_set foo"
  out="$(run_backend "secret_get foo")"
  [ "${out}" = "pw-verbatim" ] || fail "expected 'pw-verbatim', got '${out}'"
}

@test "secret/libsecret.sh: secret_delete removes the entry" {
  printf 'pw' | run_backend "secret_set foo"
  run_backend "secret_delete foo"
  val="$(jq -r '.foo // ""' "${LIBSECRET_STUB_STORE}")"
  [ -z "${val}" ] || fail "entry should be deleted, but found '${val}'"
}

@test "secret/libsecret.sh: secret_delete is idempotent (no-op on missing — wraps secret-tool clear's exit-1)" {
  run_backend "secret_delete never-set"
}

@test "secret/libsecret.sh: secret_exists returns 0 if present, non-zero if not" {
  run bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/secret/libsecret.sh'
    secret_exists foo
  "
  [ "${status}" -ne 0 ] || fail "secret_exists on missing should be non-zero (got ${status})"

  printf 'pw' | run_backend "secret_set foo"
  run bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/secret/libsecret.sh'
    secret_exists foo
  "
  [ "${status}" = "0" ] || fail "secret_exists on present should be 0 (got ${status})"
}

@test "secret/libsecret.sh: assert_safe_name rejects path traversal" {
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/secret/libsecret.sh'
    printf 'pw' | secret_set '../escape'
  "
  [ "${status}" -ne 0 ] || fail "secret_set with '../escape' should fail"
}

@test "secret/libsecret.sh: multiple secrets coexist independently" {
  printf 'alpha' | run_backend "secret_set foo"
  printf 'beta'  | run_backend "secret_set bar"
  out_foo="$(run_backend "secret_get foo")"
  out_bar="$(run_backend "secret_get bar")"
  [ "${out_foo}" = "alpha" ]
  [ "${out_bar}" = "beta" ]
}

@test "secret/libsecret.sh: last-write-wins on overwrite (clear-then-store pattern)" {
  printf 'old' | run_backend "secret_set foo"
  printf 'new' | run_backend "secret_set foo"
  out="$(run_backend "secret_get foo")"
  [ "${out}" = "new" ] || fail "expected 'new', got '${out}'"
}

@test "secret/libsecret.sh: secret_get on missing exits non-zero" {
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/secret/libsecret.sh'
    secret_get never-set
  "
  [ "${status}" -ne 0 ] || fail "secret_get on missing should fail"
}

@test "secret/libsecret.sh: default service prefix is 'browser-skill' (visible in stub log)" {
  printf 'pw' | run_backend "secret_set foo"
  if ! grep -q '^browser-skill$' "${STUB_LOG_FILE}"; then
    fail "expected service prefix 'browser-skill' in stub log; log:\n$(cat "${STUB_LOG_FILE}")"
  fi
}

@test "secret/libsecret.sh: BROWSER_SKILL_LIBSECRET_SERVICE override is honored" {
  printf 'pw' | BROWSER_SKILL_LIBSECRET_SERVICE=custom-prefix run_backend "secret_set foo"
  if ! grep -q '^custom-prefix$' "${STUB_LOG_FILE}"; then
    fail "expected custom service prefix in stub log"
  fi
}
