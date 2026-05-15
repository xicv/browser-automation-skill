load helpers

# Tests for Phase 12 — per-action telemetry / browser-stats verb family.
# Covers: stats_random_id, stats_classify_failure, stats_postcond_check,
# end-to-end emit → rebuild → report, and the user-override `mark` subcommand.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  # Avoid bleeding test-environment env vars into the emitter.
  unset BROWSER_STATS_EXPECT_TYPE BROWSER_STATS_EXPECT_MATCH BROWSER_STATS_EXPECT_VALUE BROWSER_STATS_OBSERVED
  unset CLAUDE_MODEL CLAUDE_USAGE_INPUT_TOKENS CLAUDE_USAGE_OUTPUT_TOKENS
  unset CLAUDE_USAGE_CACHE_READ_TOKENS CLAUDE_USAGE_CACHE_CREATE_TOKENS
}
teardown() {
  teardown_temp_home
}

# --- Unit: stats_random_id -------------------------------------------------

@test "stats_random_id: returns 16 lowercase hex chars (fork-free path)" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  init_paths
  local id
  id="$(stats_random_id)"
  [ "${#id}" -eq 16 ]
  [[ "${id}" =~ ^[0-9a-f]{16}$ ]]
}

@test "stats_random_id: STATS_USE_CRYPTO_ID=1 uses openssl when available" {
  command -v openssl >/dev/null 2>&1 || skip "openssl not available"
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  init_paths
  STATS_USE_CRYPTO_ID=1
  local id
  id="$(stats_random_id)"
  [ "${#id}" -eq 16 ]
  [[ "${id}" =~ ^[0-9a-f]{16}$ ]]
}

# --- Unit: stats_classify_failure ----------------------------------------

@test "stats_classify_failure: rc=0 returns empty" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  result="$(stats_classify_failure 0 "" "")"
  [ -z "${result}" ]
}

@test "stats_classify_failure: rc=43 → action_timeout (EXIT_TOOL_TIMEOUT)" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  result="$(stats_classify_failure 43 "" "timeout 5000ms exceeded")"
  [ "${result}" = "action_timeout" ]
}

@test "stats_classify_failure: rc=22 → auth_required (EXIT_SESSION_EXPIRED)" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  result="$(stats_classify_failure 22 "" "")"
  [ "${result}" = "auth_required" ]
}

@test "stats_classify_failure: stdout substring 'captcha' classifies as captcha_blocked" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  result="$(stats_classify_failure 1 "Got blocked by captcha" "")"
  [ "${result}" = "captcha_blocked" ]
}

@test "stats_classify_failure: stderr 'net::ERR_CONNECTION' classifies as network_error" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  result="$(stats_classify_failure 1 "" "net::ERR_CONNECTION_REFUSED")"
  [ "${result}" = "network_error" ]
}

# --- Unit: stats_postcond_check -----------------------------------------

@test "stats_postcond_check: exact match hits" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  run stats_postcond_check url exact "https://x.com/" "https://x.com/"
  [ "${status}" -eq 0 ]
}

@test "stats_postcond_check: include match on substring" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  run stats_postcond_check element_value include "Saved" "Saved successfully"
  [ "${status}" -eq 0 ]
}

@test "stats_postcond_check: semantic (v1 = case-insensitive substring)" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  run stats_postcond_check element_value semantic "saved" "Successfully SAVED!"
  [ "${status}" -eq 0 ]
}

@test "stats_postcond_check: miss returns 1" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  run stats_postcond_check url include "missing-string" "https://x.com/"
  [ "${status}" -eq 1 ]
}

# --- Integration: emit → JSONL line ----------------------------------------

@test "stats_run_adapter_emit: writes one valid JSONL line with required fields" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/output.sh"
  source "${LIB_DIR}/stats.sh"
  init_paths
  local t0
  t0="$(now_ms)"
  stats_run_adapter_emit "click" "chrome-devtools-mcp" "${t0}" "0" "ok" "" -- --ref e3
  [ -s "${BROWSER_SKILL_HOME}/memory/stats.jsonl" ]
  # File mode must be 0600.
  local mode
  mode="$(file_mode "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  [ "${mode}" = "600" ] || [ "${mode}" = "0600" ]
  # Single line, parses as JSON, has required fields.
  local line
  line="$(head -1 "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  printf '%s' "${line}" | jq -e '
    .schema_version == 1
    and .verb == "click"
    and .adapter_route == "chrome-devtools-mcp"
    and .outcome == "success"
    and .selector_kind == "a11y_ref"
    and .selector_value == "e3"
    and (.span_id | test("^[0-9a-f]{16}$"))
  ' >/dev/null
}

@test "stats_run_adapter_emit: oblivious_success detected when post-cond fails on rc=0" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/output.sh"
  source "${LIB_DIR}/stats.sh"
  init_paths
  local t0
  t0="$(now_ms)"
  BROWSER_STATS_EXPECT_TYPE=url \
  BROWSER_STATS_EXPECT_MATCH=include \
  BROWSER_STATS_EXPECT_VALUE="missing-string" \
  BROWSER_STATS_OBSERVED="https://example.com/" \
    stats_run_adapter_emit "open" "playwright-cli" "${t0}" "0" "navigated" "" -- --url https://example.com/
  local line
  line="$(head -1 "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  printf '%s' "${line}" | jq -e '
    .outcome == "partial"
    and .failure_mode == "oblivious_success"
    and .post_condition_hit == false
  ' >/dev/null
}

# --- Integration: rebuild + report -----------------------------------------

@test "browser-stats rebuild + report: indexes events and renders summary" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/output.sh"
  source "${LIB_DIR}/stats.sh"
  init_paths
  local t0
  t0="$(now_ms)"
  stats_run_adapter_emit "click" "chrome-devtools-mcp" "${t0}" "0" "ok" "" -- --ref e3
  stats_run_adapter_emit "open"  "playwright-cli"      "${t0}" "0" "navigated" "" -- --url https://example.com/
  stats_run_adapter_emit "fill"  "playwright-lib"      "${t0}" "43" "" "timeout exceeded" -- --selector .x --text hi

  run bash "${SCRIPTS_DIR}/browser-stats.sh" rebuild
  [ "${status}" -eq 0 ]
  [ -s "${BROWSER_SKILL_HOME}/memory/stats.db" ]

  run bash "${SCRIPTS_DIR}/browser-stats.sh" report --days 30
  [ "${status}" -eq 0 ]
  # emit_summary writes a final JSON line on stdout. Verify it carries the
  # expected verb + status + events count.
  printf '%s\n' "${output}" | tail -1 | jq -e '
    .verb == "stats" and .status == "ok" and .events == 3
  ' >/dev/null
}

# --- Integration: mark override ----------------------------------------

@test "browser-stats mark: records user override for known span_id" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/output.sh"
  source "${LIB_DIR}/stats.sh"
  init_paths
  local t0
  t0="$(now_ms)"
  stats_run_adapter_emit "click" "chrome-devtools-mcp" "${t0}" "0" "ok" "" -- --ref e3
  bash "${SCRIPTS_DIR}/browser-stats.sh" rebuild >/dev/null

  local span
  span="$(jq -sr '.[0].span_id' "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  [ "${#span}" -eq 16 ]

  run bash "${SCRIPTS_DIR}/browser-stats.sh" mark "${span}" "fail:wrong_element_acted"
  [ "${status}" -eq 0 ]

  local row
  row="$(sqlite3 "${BROWSER_SKILL_HOME}/memory/stats.db" \
    "SELECT verdict || '|' || COALESCE(reason,'') FROM stats_overrides WHERE span_id='${span}';")"
  [ "${row}" = "fail|wrong_element_acted" ]
}

@test "browser-stats mark: invalid verdict rejected with EXIT_USAGE_ERROR" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  run bash "${SCRIPTS_DIR}/browser-stats.sh" mark "deadbeefdeadbeef" "maybe"
  [ "${status}" -eq "${EXIT_USAGE_ERROR}" ]
  printf '%s' "${output}" | grep -q "verdict must be"
}
