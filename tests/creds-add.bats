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

  # Pre-create the plaintext-acknowledged marker so existing tests using
  # plaintext backend don't hit the first-use gate (added in part 2d-iii).
  # Tests that exercise the gate flow remove this marker explicitly.
  mkdir -p "${BROWSER_SKILL_HOME}/credentials"
  chmod 700 "${BROWSER_SKILL_HOME}/credentials"
  : > "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
  chmod 600 "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
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

# --- First-use plaintext gate (part 2d-iii) ---

@test "creds-add: plaintext + no marker + no flag → exit 2 with hint" {
  rm -f "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
  run bash -c "printf 'pw' | bash '${SCRIPTS_DIR}/browser-creds-add.sh' --site prod --as prod--first --backend plaintext --password-stdin"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR (2), got ${status}"
  printf '%s' "${output}" | grep -q "yes-i-know-plaintext" || fail "error message should mention --yes-i-know-plaintext flag"
}

@test "creds-add: plaintext + no marker + --yes-i-know-plaintext → succeeds + creates marker" {
  rm -f "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
  printf 'pw' | run_creds_add --site prod --as prod--first --backend plaintext --password-stdin --yes-i-know-plaintext
  [ -f "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged" ] || fail "marker should be created"
  mode="$(file_mode "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged")"
  [ "${mode}" = "600" ] || fail "marker should be mode 600, got ${mode}"
}

@test "creds-add: plaintext + marker pre-existing + no flag → succeeds (silent)" {
  # marker is pre-created by setup(); no need to remove
  printf 'pw' | run_creds_add --site prod --as prod--silent --backend plaintext --password-stdin
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--silent.json" ] || fail "should have succeeded silently"
}

@test "creds-add: keychain backend skips first-use plaintext gate" {
  # No marker, no --yes-i-know-plaintext, but backend is keychain — gate doesn't apply.
  rm -f "${BROWSER_SKILL_HOME}/credentials/.plaintext-acknowledged"
  printf 'pw-kc' | run_creds_add --site prod --as prod--kc --backend keychain --password-stdin
  [ -f "${BROWSER_SKILL_HOME}/credentials/prod--kc.json" ] || fail "keychain add should not be gated"
}

# --- Phase 5 part 3-iii: --auth-flow flag --------------------------------

@test "creds-add (3-iii): no --auth-flow → defaults to single-step-username-password" {
  printf 'pw' | run_creds_add --site prod --as prod--default-flow --backend plaintext --password-stdin
  flow="$(jq -r .auth_flow "${BROWSER_SKILL_HOME}/credentials/prod--default-flow.json")"
  [ "${flow}" = "single-step-username-password" ] \
    || fail "default auth_flow should be single-step-username-password, got ${flow}"
}

@test "creds-add (3-iii): --auth-flow multi-step-username-password persists value" {
  printf 'pw' | run_creds_add --site prod --as prod--multistep --backend plaintext --password-stdin --auth-flow multi-step-username-password
  flow="$(jq -r .auth_flow "${BROWSER_SKILL_HOME}/credentials/prod--multistep.json")"
  [ "${flow}" = "multi-step-username-password" ] \
    || fail "auth_flow should be persisted as multi-step-username-password, got ${flow}"
}

@test "creds-add (3-iii): --auth-flow username-only persists value" {
  printf 'pw' | run_creds_add --site prod --as prod--userpass --backend plaintext --password-stdin --auth-flow username-only
  flow="$(jq -r .auth_flow "${BROWSER_SKILL_HOME}/credentials/prod--userpass.json")"
  [ "${flow}" = "username-only" ] || fail "auth_flow=username-only not persisted; got ${flow}"
}

@test "creds-add (3-iii): --auth-flow custom persists value" {
  printf 'pw' | run_creds_add --site prod --as prod--custom --backend plaintext --password-stdin --auth-flow custom
  flow="$(jq -r .auth_flow "${BROWSER_SKILL_HOME}/credentials/prod--custom.json")"
  [ "${flow}" = "custom" ] || fail "auth_flow=custom not persisted; got ${flow}"
}

@test "creds-add (3-iii): --auth-flow with invalid value fails EXIT_USAGE_ERROR" {
  run bash -c "printf 'pw' | bash '${SCRIPTS_DIR}/browser-creds-add.sh' --site prod --as prod--bogus --backend plaintext --password-stdin --auth-flow ghost-flow"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
  printf '%s' "${output}" | grep -q "must be one of" || fail "error should list valid values"
}
