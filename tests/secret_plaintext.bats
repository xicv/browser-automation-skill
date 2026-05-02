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

# All tests source the backend in a subshell so `set_secret` etc. don't leak
# into the test harness's namespace.

run_backend() {
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/secret/plaintext.sh'
    $*
  "
}

@test "secret/plaintext.sh: file exists and is readable" {
  [ -f "${LIB_DIR}/secret/plaintext.sh" ] || fail "backend file missing"
  [ -r "${LIB_DIR}/secret/plaintext.sh" ] || fail "backend not readable"
}

@test "secret/plaintext.sh: secret_set reads stdin and writes a 0600 file" {
  printf 'pw-roundtrip' | run_backend "secret_set foo"
  [ -f "${BROWSER_SKILL_HOME}/credentials/foo.secret" ]
  mode="$(file_mode "${BROWSER_SKILL_HOME}/credentials/foo.secret")"
  [ "${mode}" = "600" ] || fail "expected mode 600, got ${mode}"
}

@test "secret/plaintext.sh: secret_get echoes the payload verbatim" {
  printf 'pw-verbatim' | run_backend "secret_set foo"
  out="$(run_backend "secret_get foo")"
  [ "${out}" = "pw-verbatim" ] || fail "expected 'pw-verbatim', got '${out}'"
}

@test "secret/plaintext.sh: secret_set creates CREDENTIALS_DIR with mode 700 if missing" {
  [ ! -d "${BROWSER_SKILL_HOME}/credentials" ] || rmdir "${BROWSER_SKILL_HOME}/credentials"
  printf 'pw' | run_backend "secret_set foo"
  [ -d "${BROWSER_SKILL_HOME}/credentials" ]
  mode="$(file_mode "${BROWSER_SKILL_HOME}/credentials")"
  [ "${mode}" = "700" ] || fail "expected mode 700, got ${mode}"
}

@test "secret/plaintext.sh: secret_delete removes the file" {
  printf 'pw' | run_backend "secret_set foo"
  run_backend "secret_delete foo"
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/foo.secret" ] || fail "file still present after delete"
}

@test "secret/plaintext.sh: secret_delete is idempotent (no-op on missing)" {
  run_backend "secret_delete never-set"
}

@test "secret/plaintext.sh: secret_exists returns 0 when file present, non-zero when not" {
  run bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/secret/plaintext.sh'
    secret_exists foo && exit 42 || true
  "
  [ "${status}" = "0" ] || fail "secret_exists on missing should return non-zero (got ${status})"

  printf 'pw' | run_backend "secret_set foo"
  run bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/secret/plaintext.sh'
    secret_exists foo
  "
  [ "${status}" = "0" ] || fail "secret_exists on present should return 0 (got ${status})"
}

@test "secret/plaintext.sh: assert_safe_name rejects path traversal" {
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/secret/plaintext.sh'
    printf 'pw' | secret_set '../escape'
  "
  [ "${status}" -ne 0 ] || fail "secret_set with '../escape' should have failed"
}

@test "secret/plaintext.sh: multiple secrets coexist independently" {
  printf 'alpha' | run_backend "secret_set foo"
  printf 'beta'  | run_backend "secret_set bar"
  out_foo="$(run_backend "secret_get foo")"
  out_bar="$(run_backend "secret_get bar")"
  [ "${out_foo}" = "alpha" ]
  [ "${out_bar}" = "beta" ]
}

@test "secret/plaintext.sh: secret_set overwrites existing payload (last-write-wins)" {
  printf 'old' | run_backend "secret_set foo"
  printf 'new' | run_backend "secret_set foo"
  out="$(run_backend "secret_get foo")"
  [ "${out}" = "new" ]
}

@test "secret/plaintext.sh: secret_get on missing exits non-zero" {
  run bash -c "
    set +e
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/secret/plaintext.sh'
    secret_get never-set
  "
  [ "${status}" -ne 0 ] || fail "secret_get on missing should have failed"
}

@test "secret/plaintext.sh: AP-7 — secret never appears in argv (stdin-only)" {
  # If a future contributor accidentally accepts the secret as an argv arg,
  # this test catches it via process snapshot. We can't intercept ps from
  # inside a bats test, but we can grep the source for the anti-pattern.
  if grep -nE 'secret_set\s*\(\)\s*\{[^}]*\$2' "${LIB_DIR}/secret/plaintext.sh"; then
    fail "secret_set appears to accept a positional secret arg — AP-7 violation"
  fi
}
