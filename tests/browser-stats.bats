bats_require_minimum_version 1.5.0

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

# --- Phase 14 (Bundle #3): unknown_failure fallback ----------------------

@test "stats_classify_failure: rc!=0 with no markers falls back to unknown_failure" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  result="$(stats_classify_failure 1 "" "")"
  [ "${result}" = "unknown_failure" ] \
    || fail "expected unknown_failure, got '${result}'"
}

@test "stats_classify_failure: rc!=0 with stdout-only generic error falls back to unknown_failure" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  result="$(stats_classify_failure 1 "something weird happened" "")"
  [ "${result}" = "unknown_failure" ] \
    || fail "expected unknown_failure for unrecognised text, got '${result}'"
}

@test "stats_classify_failure: known exit code still wins over unknown_failure" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  result="$(stats_classify_failure 43 "" "")"
  [ "${result}" = "action_timeout" ] || fail "rc=43 should classify; got '${result}'"
}

@test "stats_classify_failure: known stderr pattern still wins over unknown_failure" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/stats.sh"
  result="$(stats_classify_failure 1 "" "captcha required")"
  [ "${result}" = "captcha_blocked" ] || fail "pattern match should win; got '${result}'"
}

@test "stats_run_adapter_emit: rc=1 with no markers writes failure_mode=unknown_failure" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/output.sh"
  source "${LIB_DIR}/stats.sh"
  init_paths
  local t0
  t0="$(now_ms)"
  stats_run_adapter_emit "extract" "chrome-devtools-mcp" "${t0}" 1 "" "" -- --selector .x
  local event
  event="$(tail -1 "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  printf '%s' "${event}" | jq -e '.failure_mode == "unknown_failure"' >/dev/null \
    || fail "expected failure_mode=unknown_failure; event: ${event}"
  printf '%s' "${event}" | jq -e '.outcome == "fail"' >/dev/null \
    || fail "outcome should remain fail; event: ${event}"
}

@test "stats_run_adapter_emit: rc=1 unknown_failure emits self-healing hint on stderr" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/output.sh"
  source "${LIB_DIR}/stats.sh"
  init_paths
  local t0
  t0="$(now_ms)"
  # Capture stderr only.
  run --separate-stderr bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/output.sh'
    source '${LIB_DIR}/stats.sh'
    init_paths
    stats_run_adapter_emit 'extract' 'chrome-devtools-mcp' \"\$(now_ms)\" 1 '' '' -- --selector .x
  "
  # bats 1.13's $stderr holds the captured error stream.
  case "${stderr:-}" in
    *"no diagnosable signal"*) : ;;
    *) fail "expected self-healing hint on stderr; got: ${stderr:-(empty)}" ;;
  esac
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

@test "browser-stats report: rejects non-integer --days" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  run bash "${SCRIPTS_DIR}/browser-stats.sh" report --days "1'); DROP TABLE stats_events;--"
  [ "${status}" -eq "${EXIT_USAGE_ERROR}" ]
  assert_output_contains "--days must be a non-negative integer"
}

@test "browser-stats report: quotes route and verb filters" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  mkdir -p "${BROWSER_SKILL_HOME}/memory"
  chmod 700 "${BROWSER_SKILL_HOME}/memory"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '
    {schema_version:1, ts:$ts,
     span_id:"1111111111111111", trace_id:"1111111111111111",
     parent_span_id:null, session_id:null,
     gen_ai_operation_name:"execute_tool",
     gen_ai_tool_name:"odd.click",
     gen_ai_tool_type:"function",
     verb:"click'\''odd", adapter_route:"route'\''odd",
     site:null, selector_kind:"none", selector_value:null,
     duration_ms:1, argv_bytes:0, stdout_bytes:0, stderr_bytes:0,
     rc:0, outcome:"success", failure_mode:null}' \
    > "${BROWSER_SKILL_HOME}/memory/stats.jsonl"
  chmod 600 "${BROWSER_SKILL_HOME}/memory/stats.jsonl"

  run bash "${SCRIPTS_DIR}/browser-stats.sh" report --days 30 --route "route'odd" --verb "click'odd"
  [ "${status}" -eq 0 ] || fail "report failed: ${output}"
  summary="$(printf '%s\n' "${output}" | tail -1)"
  printf '%s' "${summary}" | jq -e '.verb == "stats" and .status == "ok" and .events == 1' >/dev/null \
    || fail "summary wrong: ${summary}"
}

@test "browser-stats rebuild: numeric fields are sanitized before SQL import" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  mkdir -p "${BROWSER_SKILL_HOME}/memory"
  chmod 700 "${BROWSER_SKILL_HOME}/memory"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
    --arg bad "0); DROP TABLE stats_events;--" '
    {schema_version:1, ts:$ts,
     span_id:"2222222222222222", trace_id:"2222222222222222",
     parent_span_id:null, session_id:null,
     gen_ai_operation_name:"invoke_agent",
     gen_ai_tool_name:"browser-delegate.webwright",
     gen_ai_tool_type:"function",
     verb:"delegate", adapter_route:"browser-delegate",
     delegate_backend:"webwright", delegate_model:"glm-5.1",
     delegate_steps:$bad,
     site:null, selector_kind:"none", selector_value:null,
     duration_ms:$bad, argv_bytes:"12", stdout_bytes:"nope", stderr_bytes:0,
     rc:0, outcome:"success", failure_mode:null,
     offloaded_input_tokens:"5",
     offloaded_output_tokens:$bad,
     offloaded_cached_input_tokens:"7"}' \
    > "${BROWSER_SKILL_HOME}/memory/stats.jsonl"
  chmod 600 "${BROWSER_SKILL_HOME}/memory/stats.jsonl"

  run bash "${SCRIPTS_DIR}/browser-stats.sh" rebuild
  [ "${status}" -eq 0 ] || fail "rebuild failed: ${output}"
  table_count="$(sqlite3 "${BROWSER_SKILL_HOME}/memory/stats.db" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='stats_events';")"
  [ "${table_count}" = "1" ] || fail "stats_events table missing after rebuild"
  row="$(sqlite3 "${BROWSER_SKILL_HOME}/memory/stats.db" "
    SELECT
      (duration_ms IS NULL) || '|' ||
      argv_bytes || '|' ||
      (stdout_bytes IS NULL) || '|' ||
      rc || '|' ||
      (delegate_steps IS NULL) || '|' ||
      offloaded_input_tokens || '|' ||
      (offloaded_output_tokens IS NULL) || '|' ||
      offloaded_cached_input_tokens
    FROM stats_events WHERE span_id='2222222222222222';")"
  [ "${row}" = "1|12|1|0|1|5|1|7" ] \
    || fail "numeric sanitization row wrong: ${row}"
}

@test "browser-stats rebuild + report: indexes delegate offloaded token fields" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  sqlite3 :memory: "SELECT json_extract('{\"a\":1}', '$.a');" >/dev/null 2>&1 \
    || skip "sqlite3 JSON functions not available"
  mkdir -p "${BROWSER_SKILL_HOME}/memory"
  chmod 700 "${BROWSER_SKILL_HOME}/memory"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '
    {schema_version:1, ts:$ts,
     span_id:"0000000000000001", trace_id:"0000000000000001",
     parent_span_id:null, session_id:null,
     gen_ai_operation_name:"invoke_agent",
     gen_ai_tool_name:"browser-delegate.webwright",
     gen_ai_tool_type:"function",
     verb:"delegate", adapter_route:"browser-delegate",
     delegate_backend:"webwright", delegate_model:"glm-4.5",
     delegate_steps:3,
     site:null, selector_kind:"none", selector_value:null,
     duration_ms:4200, argv_bytes:0, stdout_bytes:18, stderr_bytes:0,
     rc:0, outcome:"success", failure_mode:null,
     offloaded_input_tokens:1000,
     offloaded_output_tokens:200,
     offloaded_cached_input_tokens:300}' \
    > "${BROWSER_SKILL_HOME}/memory/stats.jsonl"
  chmod 600 "${BROWSER_SKILL_HOME}/memory/stats.jsonl"

  run bash "${SCRIPTS_DIR}/browser-stats.sh" rebuild
  [ "${status}" -eq 0 ] || fail "rebuild failed: ${output}"
  row="$(sqlite3 "${BROWSER_SKILL_HOME}/memory/stats.db" \
    "SELECT delegate_backend || '|' || delegate_model || '|' || delegate_steps || '|' || offloaded_input_tokens || '|' || offloaded_output_tokens || '|' || offloaded_cached_input_tokens FROM stats_events WHERE adapter_route='browser-delegate';")"
  [ "${row}" = "webwright|glm-4.5|3|1000|200|300" ] \
    || fail "delegate columns not indexed correctly: ${row}"

  run bash "${SCRIPTS_DIR}/browser-stats.sh" report --days 30
  [ "${status}" -eq 0 ] || fail "report failed: ${output}"
  assert_output_contains "Delegation offload"
  assert_output_contains "webwright"
  assert_output_contains "glm-4.5"
  summary="$(printf '%s\n' "${output}" | tail -1)"
  printf '%s' "${summary}" | jq -e '
    .verb == "stats"
    and .status == "ok"
    and .events == 1
    and .delegate_events == 1
    and .offloaded_total_tokens == 1500
  ' >/dev/null || fail "summary wrong: ${summary}"
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

# ---------- Phase 14+ stats prune (cache-quality feedback loop) ----------

# Seed N oblivious_success events at the same (site, selector) into stats.jsonl
# so prune has work to do. Each event uses a fresh span_id.
_seed_oblivious_events() {
  local site="$1" selector="$2" count="$3"
  local file="${BROWSER_SKILL_HOME}/memory/stats.jsonl"
  mkdir -p "$(dirname "${file}")"
  chmod 700 "${BROWSER_SKILL_HOME}/memory"
  local i
  for i in $(seq 1 "${count}"); do
    local sid
    sid="$(printf '%016x' "$((RANDOM * RANDOM + i))")"
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
      --arg span_id "${sid}" \
      --arg site "${site}" \
      --arg sel "${selector}" '
      {schema_version:1, ts:$ts, span_id:$span_id, trace_id:$span_id,
       parent_span_id:null, session_id:null,
       gen_ai_operation_name:"execute_tool",
       gen_ai_tool_name:"playwright-cli.click",
       gen_ai_tool_type:"function",
       verb:"click", adapter_route:"playwright-cli",
       site:$site, selector_kind:"css", selector_value:$sel,
       duration_ms:50, argv_bytes:20, stdout_bytes:0, stderr_bytes:0,
       rc:0, outcome:"partial",
       failure_mode:"oblivious_success",
       post_condition_target_type:"url", post_condition_matcher:"include",
       post_condition_expected:"/dashboard",
       post_condition_observed:"https://example.com/login",
       post_condition_hit:false}' >> "${file}"
  done
  chmod 600 "${file}"
}

# Seed an archetype with one interaction matching the given selector.
_seed_archetype_for_prune() {
  local site="$1" archetype_id="$2" intent="$3" selector="$4"
  local dir="${BROWSER_SKILL_HOME}/memory/${site}/archetypes"
  mkdir -p "${dir}"
  chmod 700 "${dir}"
  jq -n --arg id "${archetype_id}" --arg intent "${intent}" --arg sel "${selector}" '
    {archetype_id:$id, url_pattern:"/dashboard",
     interactions:[
       {intent:$intent, selector:$sel, verb:"click",
        fail_count:0, disabled:false}
     ]}' > "${dir}/${archetype_id}.json"
  chmod 600 "${dir}/${archetype_id}.json"
  # patterns.json so archetype resolves.
  jq -n --arg id "${archetype_id}" '
    {patterns:[{url_pattern:"/dashboard", archetype_id:$id}], version:1}' \
    > "${BROWSER_SKILL_HOME}/memory/${site}/patterns.json"
  chmod 600 "${BROWSER_SKILL_HOME}/memory/${site}/patterns.json"
}

@test "browser-stats prune: dry-run lists candidates above threshold" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  _seed_oblivious_events app1 "button.delete" 4
  _seed_archetype_for_prune app1 dashboard "click delete" "button.delete"
  run bash "${SCRIPTS_DIR}/browser-stats.sh" prune
  [ "${status}" -eq 0 ] || fail "prune exit=${status}; output:\n${output}"
  local cand_line
  cand_line="$(printf '%s\n' "${lines[@]}" \
    | jq -c 'select(._kind == "prune_candidate")' | head -1)"
  [ -n "${cand_line}" ] \
    || fail "no prune_candidate line emitted; output:\n${output}"
  printf '%s' "${cand_line}" | jq -e '.site == "app1"' >/dev/null
  printf '%s' "${cand_line}" | jq -e '.selector == "button.delete"' >/dev/null
  printf '%s' "${cand_line}" | jq -e '.oblivious_success_count >= 3' >/dev/null
  printf '%s' "${cand_line}" | jq -e '.archetype_id == "dashboard"' >/dev/null
  # Summary line.
  local summary
  summary="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${summary}" | jq -e '.verb == "stats" and .why == "prune" and .candidates >= 1 and .applied == 0' >/dev/null \
    || fail "summary wrong: ${summary}"
}

@test "browser-stats prune --apply: sets .disabled=true on matching interaction" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  _seed_oblivious_events app2 "input.email" 5
  _seed_archetype_for_prune app2 login "fill email" "input.email"
  arch_path="${BROWSER_SKILL_HOME}/memory/app2/archetypes/login.json"
  jq -e '.interactions[0].disabled == false' "${arch_path}" >/dev/null \
    || fail "precondition: disabled should be false"
  run bash "${SCRIPTS_DIR}/browser-stats.sh" prune --apply
  [ "${status}" -eq 0 ] || fail "prune --apply exit=${status}; output:\n${output}"
  jq -e '.interactions[0].disabled == true' "${arch_path}" >/dev/null \
    || fail "disabled should be true after --apply; got $(jq -c '.interactions[0]' "${arch_path}")"
  # Applied event emitted.
  local applied_line
  applied_line="$(printf '%s\n' "${lines[@]}" \
    | jq -c 'select(._kind == "prune_applied")' | head -1)"
  [ -n "${applied_line}" ] \
    || fail "no prune_applied line emitted; output:\n${output}"
}

@test "browser-stats prune: --threshold above actual count → zero candidates" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  _seed_oblivious_events app3 "button.x" 2
  _seed_archetype_for_prune app3 page "click x" "button.x"
  run bash "${SCRIPTS_DIR}/browser-stats.sh" prune --threshold 10
  [ "${status}" -eq 0 ]
  if printf '%s\n' "${lines[@]}" | jq -e 'select(._kind == "prune_candidate")' >/dev/null 2>&1; then
    fail "expected zero candidates at threshold=10; got: ${output}"
  fi
  local summary
  summary="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${summary}" | jq -e '.candidates == 0' >/dev/null
}

@test "browser-stats prune: --site filter narrows to one site" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
  _seed_oblivious_events alpha "button.a" 4
  _seed_oblivious_events beta  "button.b" 4
  _seed_archetype_for_prune alpha pg "click a" "button.a"
  _seed_archetype_for_prune beta  pg "click b" "button.b"
  run bash "${SCRIPTS_DIR}/browser-stats.sh" prune --site alpha
  [ "${status}" -eq 0 ]
  local sites
  sites="$(printf '%s\n' "${lines[@]}" \
    | jq -r 'select(._kind == "prune_candidate") | .site' | sort -u)"
  [ "${sites}" = "alpha" ] \
    || fail "--site filter leaked beyond alpha; got '${sites}'"
}
