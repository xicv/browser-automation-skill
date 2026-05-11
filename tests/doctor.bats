load helpers

@test "doctor: prints resolved BROWSER_SKILL_HOME at top" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "${BROWSER_SKILL_HOME}"
}

@test "doctor: passes when bash, jq, python3 are present" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "all checks passed"
}

@test "doctor: emits a final JSON summary line on stdout" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "doctor"' >/dev/null
}

@test "doctor: warns when ~/.browser-skill missing" {
  setup_temp_home
  # Don't create BROWSER_SKILL_HOME — should be flagged.
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "$EXIT_PREFLIGHT_FAILED"
  assert_output_contains "does not exist"
}

@test "doctor: warns when ~/.browser-skill mode is not 0700" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 0755 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "$EXIT_PREFLIGHT_FAILED"
  assert_output_contains "mode 755"
  assert_output_contains "expected 700"
}

@test "doctor: prints disk-encryption status (advisory, never fails)" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "disk encryption"
}

@test "doctor: missing node fails doctor (required from Phase 3 onward)" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  local stub="${TEST_HOME}/bin"
  mkdir -p "${stub}"
  ln -s "$(command -v bash)" "${stub}/bash"
  ln -s "$(command -v jq)" "${stub}/jq"
  ln -s "$(command -v python3)" "${stub}/python3"
  PATH="${stub}:/usr/sbin:/bin:/usr/bin" run "${stub}/bash" "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "$EXIT_PREFLIGHT_FAILED"
  assert_output_contains "node NOT FOUND"
}

@test "doctor: reports each adapter under lib/tool/ as a check line" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "playwright-cli"
}

@test "doctor: streams a JSON line per adapter with check=adapter and adapter=<name>" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  echo "${output}" | grep -E '^\{.*"check":"adapter"' >/dev/null \
    || fail "no adapter check line found"
  echo "${output}" | grep -E '"adapter":"playwright-cli"' >/dev/null \
    || fail "playwright-cli adapter not reported"
}

@test "doctor: summary includes adapters_ok and adapters_failed counts" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  summary="$(printf '%s\n' "${output}" | tail -1)"
  printf '%s' "${summary}" | jq -e 'has("adapters_ok") and has("adapters_failed")' >/dev/null \
    || fail "summary does not include adapter counts"
}

@test "doctor: well-formed status field even when adapter binary is missing" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  summary="$(printf '%s\n' "${output}" | tail -1)"
  printf '%s' "${summary}" | jq -e '.status' >/dev/null
}

@test "doctor: prints credentials count line (zero state)" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "credentials: 0 total"
}

@test "doctor: credentials count line reflects per-backend breakdown" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/credentials"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/credentials"
  # Hand-write a plaintext-backed credential metadata file so we don't need
  # to invoke creds-add (which requires --site / --as / stub bins).
  cat > "${BROWSER_SKILL_HOME}/credentials/test--cred.json" <<'EOF'
{"schema_version":1,"name":"test--cred","site":"test","account":"a@b.c","backend":"plaintext","auth_flow":"single-step-username-password","auto_relogin":true,"totp_enabled":false,"created_at":"2026-05-03T00:00:00Z"}
EOF
  chmod 600 "${BROWSER_SKILL_HOME}/credentials/test--cred.json"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "credentials: 1 total"
  assert_output_contains "plaintext: 1"
}

# ---------- Phase 7 part 1-iv: captures sanitization counter ----------

@test "doctor: captures count line — all sanitized, no warn" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/captures/001" "${BROWSER_SKILL_HOME}/captures/002"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/captures" "${BROWSER_SKILL_HOME}/captures/001" "${BROWSER_SKILL_HOME}/captures/002"
  printf '{"capture_id":"001","verb":"snapshot","status":"ok","sanitized":true}' > "${BROWSER_SKILL_HOME}/captures/001/meta.json"
  printf '{"capture_id":"002","verb":"inspect","status":"ok","sanitized":true}'  > "${BROWSER_SKILL_HOME}/captures/002/meta.json"
  chmod 600 "${BROWSER_SKILL_HOME}/captures/001/meta.json" "${BROWSER_SKILL_HOME}/captures/002/meta.json"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "captures: 2 total"
  assert_output_contains "sanitized:false: 0"
}

@test "doctor: captures count line — mixed (1 unsanitized) emits warn" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/captures/001" "${BROWSER_SKILL_HOME}/captures/002"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/captures" "${BROWSER_SKILL_HOME}/captures/001" "${BROWSER_SKILL_HOME}/captures/002"
  printf '{"capture_id":"001","verb":"inspect","status":"ok","sanitized":true}'  > "${BROWSER_SKILL_HOME}/captures/001/meta.json"
  printf '{"capture_id":"002","verb":"inspect","status":"ok","sanitized":false}' > "${BROWSER_SKILL_HOME}/captures/002/meta.json"
  chmod 600 "${BROWSER_SKILL_HOME}/captures/001/meta.json" "${BROWSER_SKILL_HOME}/captures/002/meta.json"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "captures: 2 total"
  assert_output_contains "sanitized:false: 1"
  assert_output_contains "sanitization disabled"
}

# ---------- Phase 10 follow-up: pending migrations surfaced by doctor ----------
# Doctor calls migrate_check (read-only; no lock per MIG4 invariant) and reports
# pending migration count as advisory output. Never auto-migrates; never fails.

@test "doctor: zero pending migrations → reports 'no pending migrations' + JSON pending:0; exit still 0" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  empty_migrators="${TEST_HOME}/empty-migrators"
  mkdir -p "${empty_migrators}"
  BROWSER_SKILL_MIGRATORS_DIR="${empty_migrators}" \
    run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "no pending migrations"
  # JSON event for machine consumers
  echo "${output}" | grep -E '"check":"migrations".*"pending":0' >/dev/null \
    || fail "expected {check:migrations,pending:0} JSON line; got:\n${output}"
}

@test "doctor: identity migrator registered → warns 'N pending migration(s)' but exit still 0" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  # Seed a fixture v1_to_v2 migrator under a test-only registry dir; default
  # schema_version=1 for fresh init means migrate_check will report it pending.
  migrators_dir="${TEST_HOME}/migrators"
  mkdir -p "${migrators_dir}/test"
  cat > "${migrators_dir}/test/v1_to_v2.sh" <<'EOF'
migrate_test_v1_to_v2() {
  local file_path="$1"
  jq . "${file_path}" > "${file_path}.tmp" && mv "${file_path}.tmp" "${file_path}"
}
EOF
  BROWSER_SKILL_MIGRATORS_DIR="${migrators_dir}" \
    run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "pending migration"
  echo "${output}" | grep -E '"check":"migrations".*"pending":1' >/dev/null \
    || fail "expected {check:migrations,pending:1} JSON line; got:\n${output}"
}

# ---------- Phase 11 v2 forward-compat: memory cache hit-rate read side ----------
# Doctor reads ${BROWSER_SKILL_HOME}/memory/events.jsonl when present and reports
# hit rate. Phase 11 v2 will tee `summary_json verb=do mode=intent ...` lines
# into this file (the write side); doctor's read side ships now.

@test "doctor: no memory events log → reports 'cache hit rate: n/a' + JSON hit_rate_pct:null" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "memory cache hit rate: n/a"
  # Phase 11 v2 part 1 has SHIPPED (PR #115). "Phase 11 v2 pending" was the
  # pre-writer text. Now: events.jsonl absent means browser-do --intent hasn't
  # been invoked on this machine yet. Pin the accurate reason so future doc
  # drift surfaces in CI.
  assert_output_contains "browser-do --intent"
  ! grep -q 'Phase 11 v2 pending' <<<"${output}" \
    || fail "stale 'Phase 11 v2 pending' text still present; Phase 11 v2 part 1 shipped in PR #115"
  echo "${output}" | grep -E '"check":"memory_cache".*"hit_rate_pct":null' >/dev/null \
    || fail "expected {check:memory_cache,hit_rate_pct:null} JSON line; got:\n${output}"
}

@test "doctor: memory events log with 3 hits / 2 misses → reports '60% (3/5 events)'" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/memory"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/memory"
  # Phase 11 v2 will tee the verb=do mode=intent summary line; doctor reads
  # .cache_hit (true|false) on lines matching that shape.
  cat > "${BROWSER_SKILL_HOME}/memory/events.jsonl" <<'EOF'
{"verb":"do","mode":"intent","cache_hit":true,"site":"a"}
{"verb":"do","mode":"intent","cache_hit":true,"site":"a"}
{"verb":"do","mode":"intent","cache_hit":false,"site":"a"}
{"verb":"do","mode":"intent","cache_hit":true,"site":"a"}
{"verb":"do","mode":"intent","cache_hit":false,"site":"a"}
EOF
  chmod 600 "${BROWSER_SKILL_HOME}/memory/events.jsonl"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "memory cache hit rate: 60%"
  assert_output_contains "(3/5 events)"
  echo "${output}" | grep -E '"check":"memory_cache".*"hits":3.*"total":5.*"hit_rate_pct":60' >/dev/null \
    || fail "expected {check:memory_cache,hits:3,total:5,hit_rate_pct:60} JSON line; got:\n${output}"
}

@test "doctor: memory events log present but empty → reports 'n/a (events log present but empty)'" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/memory"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/memory"
  : > "${BROWSER_SKILL_HOME}/memory/events.jsonl"
  chmod 600 "${BROWSER_SKILL_HOME}/memory/events.jsonl"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "memory cache hit rate: n/a"
  assert_output_contains "events log present but empty"
}
