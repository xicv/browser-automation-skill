load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  init_paths

  # Defensive: make absolutely sure no test can fall through to the real
  # macOS Keychain (which pops a system dialog on dev boxes without a
  # default keychain). Same lesson as part 2b.
  export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
  export KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"
  export LIBSECRET_STUB_STORE="${TEST_HOME}/libsecret-stub.json"

  # Always seed a 'prod' site so every test's --site prod resolves cleanly
  # without each having to register its own site.
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod --url https://app.example.com >/dev/null 2>&1 || true
}
teardown() {
  teardown_temp_home
}

run_creds_add() {
  bash "${SCRIPTS_DIR}/browser-creds-add.sh" "$@"
}

@test "creds-add: file exists and is executable" {
  [ -f "${SCRIPTS_DIR}/browser-creds-add.sh" ] || fail "verb script missing"
  [ -x "${SCRIPTS_DIR}/browser-creds-add.sh" ] || fail "verb script not executable"
}

@test "creds-add: AP-7 — script source MUST NOT contain --password VALUE flag handler (stdin-only)" {
  if grep -nE '^\s*--password\s*\)' "${SCRIPTS_DIR}/browser-creds-add.sh"; then
    fail "browser-creds-add.sh has a --password VALUE flag — AP-7 violation; secrets must come via --password-stdin only"
  fi
}

@test "creds-add: happy path with --password-stdin + --backend plaintext (roundtrip)" {
  printf 'pw-plaintext' | run_creds_add --site prod --as prod--admin --backend plaintext --password-stdin
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.json" ] || fail "metadata not written"
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret" ] || fail "secret not written"
  out="$(cat "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret")"
  [ "${out}" = "pw-plaintext" ] || fail "expected 'pw-plaintext', got '${out}'"
}

@test "creds-add: happy path with --backend keychain (via stub)" {
  printf 'pw-keychain' | run_creds_add --site prod --as prod--keychain --backend keychain --password-stdin
  val="$(jq -r '."prod--keychain"' "${KEYCHAIN_STUB_STORE}")"
  [ "${val}" = "pw-keychain" ] || fail "expected 'pw-keychain' in keychain stub, got '${val}'"
}

@test "creds-add: happy path with --backend libsecret (via stub)" {
  printf 'pw-libsecret' | run_creds_add --site prod --as prod--libsec --backend libsecret --password-stdin
  val="$(jq -r '."prod--libsec"' "${LIBSECRET_STUB_STORE}")"
  [ "${val}" = "pw-libsecret" ] || fail "expected 'pw-libsecret' in libsecret stub, got '${val}'"
}

@test "creds-add: backend auto-detect via BROWSER_SKILL_FORCE_BACKEND=plaintext" {
  printf 'pw-auto' | BROWSER_SKILL_FORCE_BACKEND=plaintext run_creds_add --site prod --as prod--auto --password-stdin
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--auto.secret" ] || fail "auto-detect did not pick plaintext"
}

@test "creds-add: rejects existing credential name (must remove first)" {
  printf 'pw1' | run_creds_add --site prod --as prod--dup --backend plaintext --password-stdin
  run bash -c "printf 'pw2' | bash '${SCRIPTS_DIR}/browser-creds-add.sh' --site prod --as prod--dup --backend plaintext --password-stdin"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR (2), got ${status}"
  assert_output_contains "already exists"
}

@test "creds-add: rejects unknown site (exit 23 SITE_NOT_FOUND)" {
  run bash -c "printf 'pw' | bash '${SCRIPTS_DIR}/browser-creds-add.sh' --site no-such-site --as foo --backend plaintext --password-stdin"
  [ "${status}" = "${EXIT_SITE_NOT_FOUND}" ] || fail "expected EXIT_SITE_NOT_FOUND (23), got ${status}"
}

@test "creds-add: --as rejected when unsafe (exit 2)" {
  run bash -c "printf 'pw' | bash '${SCRIPTS_DIR}/browser-creds-add.sh' --site prod --as '../escape' --backend plaintext --password-stdin"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR (2), got ${status}"
}

@test "creds-add: --password-stdin missing → exit 2" {
  run bash "${SCRIPTS_DIR}/browser-creds-add.sh" --site prod --as foo --backend plaintext
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
}

@test "creds-add: --site missing → exit 2" {
  run bash -c "printf 'pw' | bash '${SCRIPTS_DIR}/browser-creds-add.sh' --as foo --backend plaintext --password-stdin"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
}

@test "creds-add: --as missing → exit 2" {
  run bash -c "printf 'pw' | bash '${SCRIPTS_DIR}/browser-creds-add.sh' --site prod --backend plaintext --password-stdin"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
}

@test "creds-add: --dry-run skips writes (no metadata + no secret)" {
  printf 'pw' | run_creds_add --site prod --as prod--dryrun --backend plaintext --password-stdin --dry-run
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/prod--dryrun.json" ] || fail "metadata written despite --dry-run"
  [ ! -f "${BROWSER_SKILL_HOME}/credentials/prod--dryrun.secret" ] || fail "secret written despite --dry-run"
}

@test "creds-add: --account override appears in metadata" {
  printf 'pw' | run_creds_add --site prod --as prod--acct --backend plaintext --account 'alice@team.example' --password-stdin
  acct="$(jq -r .account "${BROWSER_SKILL_HOME}/credentials/prod--acct.json")"
  [ "${acct}" = "alice@team.example" ] || fail "expected alice@team.example, got ${acct}"
}

@test "creds-add: summary JSON has required keys" {
  out="$(printf 'pw' | run_creds_add --site prod --as prod--summary --backend plaintext --password-stdin 2>/dev/null)"
  summary="$(printf '%s\n' "${out}" | tail -1)"
  printf '%s' "${summary}" | jq -e '.verb == "creds-add"' >/dev/null
  printf '%s' "${summary}" | jq -e '.tool == "none"' >/dev/null
  printf '%s' "${summary}" | jq -e '.status == "ok"' >/dev/null
  printf '%s' "${summary}" | jq -e 'has("why") and has("duration_ms") and has("credential") and has("site") and has("backend")' >/dev/null
}
