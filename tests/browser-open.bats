load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

@test "browser-open: --url translates to positional URL at adapter boundary" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --url https://example.com
  assert_status 0
  grep -q '^open$'                "${STUB_LOG_FILE}"
  grep -q '^https://example.com$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-open: emits a single-line JSON summary as the last line of stdout" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --url https://example.com
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "open" and .tool == "playwright-cli" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.duration_ms | type == "number"' >/dev/null
}

@test "browser-open: --tool override propagates as ARG_TOOL into router" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --tool playwright-cli --url https://example.com
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.why == "user-specified"' >/dev/null
}

@test "browser-open: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-open.sh" --tool ghost-tool --url https://example.com
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-open: missing --url fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-open.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--url"
}

@test "browser-open: --dry-run prints planned action and writes nothing" {
  run bash "${SCRIPTS_DIR}/browser-open.sh" --dry-run --url https://example.com
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.status == "ok" and .dry_run == true' >/dev/null
}

# ---------- Pick A6: browser-open tees URL to recent_urls.jsonl on success ----------

@test "browser-open: successful open tees URL to recent_urls.jsonl when --site set" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name myapp --url 'https://example.com' >/dev/null
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --site myapp --url https://example.com
  assert_status 0
  log_path="${BROWSER_SKILL_HOME}/memory/recent_urls.jsonl"
  [ -f "${log_path}" ] || fail "recent_urls.jsonl was not written; output: ${output}"
  jq -e '.url == "https://example.com" and .verb == "open" and .site == "myapp"' \
    "${log_path}" >/dev/null \
    || fail "row shape wrong: $(cat "${log_path}")"
}

@test "browser-open: --dry-run does NOT tee to recent_urls.jsonl (no adapter call)" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name myapp --url 'https://example.com' >/dev/null
  run bash "${SCRIPTS_DIR}/browser-open.sh" --dry-run --site myapp --url https://example.com
  assert_status 0
  log_path="${BROWSER_SKILL_HOME}/memory/recent_urls.jsonl"
  [ ! -f "${log_path}" ] \
    || fail "recent_urls.jsonl created on --dry-run (should be skipped); contents: $(cat "${log_path}")"
}

# ---------- Phase 14 (Bundle #2): auto-derive post-condition for open ----------

@test "browser-open: auto-derives post_condition_hit=true when adapter URL contains input URL" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --url https://example.com
  assert_status 0
  local event
  event="$(tail -1 "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  printf '%s' "${event}" | jq -e '.post_condition_hit == true' >/dev/null \
    || fail "expected post_condition_hit=true (auto-derived); event: ${event}"
  printf '%s' "${event}" | jq -e '.post_condition_target_type == "url"' >/dev/null \
    || fail "expected target_type=url; event: ${event}"
  printf '%s' "${event}" | jq -e '.failure_mode == null' >/dev/null \
    || fail "happy path should have no failure_mode; event: ${event}"
}

@test "browser-open: oblivious_success fires when adapter URL does NOT contain input URL" {
  # Inline stub: claim success but return a different URL (simulated redirect-to-login).
  local stub
  stub="$(mktemp "${TMPDIR:-/tmp}/playwright-mismatch.XXXXXX")"
  cat > "${stub}" <<'EOF'
#!/usr/bin/env bash
printf '{"event":"navigate","url":"https://example.com/login","status":200}\n'
EOF
  chmod +x "${stub}"
  PLAYWRIGHT_CLI_BIN="${stub}" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --url https://wanted.example.org/dashboard
  rm -f "${stub}"
  assert_status 0
  local event
  event="$(tail -1 "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  printf '%s' "${event}" | jq -e '.post_condition_hit == false' >/dev/null \
    || fail "expected post_condition_hit=false; event: ${event}"
  printf '%s' "${event}" | jq -e '.failure_mode == "oblivious_success"' >/dev/null \
    || fail "expected failure_mode=oblivious_success; event: ${event}"
  printf '%s' "${event}" | jq -e '.outcome == "partial"' >/dev/null \
    || fail "expected outcome=partial; event: ${event}"
}

_b1_inject_devices_fixtures() {
  # Drop temporary fixtures for `open https://example.com/devices/N` (N=1..3)
  # into the playwright-cli fixtures dir so the test exercises the
  # rc=0 → memory_record_recent_url → propose chain. Cleanup via the
  # returned shas in teardown.
  fixtures_dir="$1"
  for n in 1 2 3; do
    sha=$(printf 'open\0https://example.com/devices/%s\0' "$n" | shasum -a 256 | awk '{print $1}')
    printf '{"event":"navigate","url":"https://example.com/devices/%s","status":200}\n' "$n" \
      > "${fixtures_dir}/${sha}.json"
    echo "${sha}"
  done
}
_b1_cleanup_devices_fixtures() {
  fixtures_dir="$1"; shift
  for sha in "$@"; do
    rm -f "${fixtures_dir}/${sha}.json"
  done
}

@test "browser-open B1: opportunistic propose populates patterns.json after 3+ similar URLs" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name myapp --url 'https://example.com' >/dev/null
  mapfile -t shas < <(_b1_inject_devices_fixtures "${FIXTURES_DIR}/playwright-cli")
  for n in 1 2 3; do
    PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
    PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
      bash "${SCRIPTS_DIR}/browser-open.sh" --site myapp \
        --url "https://example.com/devices/${n}" >/dev/null 2>&1
  done
  _b1_cleanup_devices_fixtures "${FIXTURES_DIR}/playwright-cli" "${shas[@]}"
  patterns_path="${BROWSER_SKILL_HOME}/memory/myapp/patterns.json"
  [ -f "${patterns_path}" ] \
    || fail "patterns.json should be written by opportunistic propose; recent_urls: $(cat "${BROWSER_SKILL_HOME}/memory/recent_urls.jsonl" 2>/dev/null)"
  jq -e '.patterns | length >= 1' "${patterns_path}" >/dev/null \
    || fail "expected ≥1 pattern in patterns.json; got $(cat "${patterns_path}")"
}

@test "browser-open B1: BROWSER_SKILL_OPEN_PROPOSE=0 opts out of opportunistic propose" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name myapp --url 'https://example.com' >/dev/null
  mapfile -t shas < <(_b1_inject_devices_fixtures "${FIXTURES_DIR}/playwright-cli")
  for n in 1 2 3; do
    BROWSER_SKILL_OPEN_PROPOSE=0 \
    PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
    PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
      bash "${SCRIPTS_DIR}/browser-open.sh" --site myapp \
        --url "https://example.com/devices/${n}" >/dev/null 2>&1
  done
  _b1_cleanup_devices_fixtures "${FIXTURES_DIR}/playwright-cli" "${shas[@]}"
  patterns_path="${BROWSER_SKILL_HOME}/memory/myapp/patterns.json"
  [ ! -f "${patterns_path}" ] \
    || fail "patterns.json should NOT be written when OPEN_PROPOSE=0; got $(cat "${patterns_path}")"
}

@test "browser-open: caller-set BROWSER_STATS_EXPECT_VALUE takes precedence over auto-derive" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  BROWSER_STATS_EXPECT_VALUE="/admin" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --url https://example.com
  # adapter_out contains "example.com" not "/admin" → expect mismatch
  assert_status 0
  local event
  event="$(tail -1 "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  printf '%s' "${event}" | jq -e '.post_condition_expected == "/admin"' >/dev/null \
    || fail "expected caller-set value preserved; event: ${event}"
  printf '%s' "${event}" | jq -e '.failure_mode == "oblivious_success"' >/dev/null \
    || fail "expected oblivious_success due to /admin not in url; event: ${event}"
}
