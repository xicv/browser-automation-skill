load helpers

# Phase 9 part 1-iv — replay <capture-id>: re-execute capture's steps +
# structured diff. Composes existing flow_dispatch from lib/flow.sh.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

# --- flow_diff_steps ---

@test "flow_diff_steps: identical events → status_match:true + output_match:true; returns 0" {
  old='{"step_index":0,"verb":"snapshot","args":{},"status":"ok","duration_ms":100,"exit_code":0,"summary":{"verb":"snapshot","status":"ok"},"refs":null}'
  new="${old}"
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_diff_steps '${old}' '${new}'
  "
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "replay_diff" and .status_match == true and .output_match == true' >/dev/null
}

@test "flow_diff_steps: status divergence (old:ok, new:error) → status_match:false; returns 1" {
  old='{"step_index":0,"verb":"snapshot","args":{},"status":"ok","exit_code":0,"summary":{"verb":"snapshot","status":"ok"}}'
  new='{"step_index":0,"verb":"snapshot","args":{},"status":"error","exit_code":1,"summary":{"verb":"snapshot","status":"error"}}'
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_diff_steps '${old}' '${new}'
  "
  [ "${status}" = "1" ] || fail "expected exit 1 (divergent); got ${status}"
  printf '%s' "${output}" | jq -e '.status_match == false and .old_status == "ok" and .new_status == "error"' >/dev/null
}

@test "flow_diff_steps: output divergence (same status, different summary) → output_match:false; returns 1" {
  old='{"step_index":0,"verb":"snapshot","args":{},"status":"ok","exit_code":0,"summary":{"verb":"snapshot","status":"ok","extra":"old"}}'
  new='{"step_index":0,"verb":"snapshot","args":{},"status":"ok","exit_code":0,"summary":{"verb":"snapshot","status":"ok","extra":"new"}}'
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_diff_steps '${old}' '${new}'
  "
  [ "${status}" = "1" ] || fail "expected exit 1 (divergent); got ${status}"
  printf '%s' "${output}" | jq -e '.status_match == true and .output_match == false' >/dev/null
}

# --- browser-replay.sh ---

@test "browser-replay.sh: missing <capture-id> fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-replay.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "capture-id"
}

@test "browser-replay.sh: nonexistent capture-id → EXIT_USAGE_ERROR with helpful message" {
  run bash "${SCRIPTS_DIR}/browser-replay.sh" 999
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such capture"
}

@test "browser-replay.sh: end-to-end → new capture with replay_of + replay_match:true; status:ok" {
  # Pre-stage: run a flow to produce captures/001.
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  BROWSER_SKILL_LIB_STUB=1 \
    bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/simple.flow.yaml" >/dev/null 2>&1
  [ -d "${BROWSER_SKILL_HOME}/captures/001" ] || fail "pre-stage: no captures/001 produced"

  # Replay it.
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-replay.sh" 001
  assert_status 0
  # New capture (002) carries replay_of + replay_match.
  [ -f "${BROWSER_SKILL_HOME}/captures/002/meta.json" ] || fail "no captures/002 produced"
  jq -e '.replay_of == "001" and .replay_match == true and .status == "ok"' \
    "${BROWSER_SKILL_HOME}/captures/002/meta.json" >/dev/null \
    || fail "captures/002/meta.json missing replay_of / replay_match / status fields"
  # Summary line carries replay_of.
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "replay" and .replay_of == "001" and .replay_match == true' >/dev/null
}

@test "browser-replay.sh: --strict on divergent replay exits 13 (ASSERTION_FAILED)" {
  # Pre-stage: produce a capture, then mutate its steps.jsonl to simulate
  # divergence on replay (first step's old.status was 'ok'; we'll modify
  # the recorded step to claim status='error' so the diff fires).
  BROWSER_SKILL_LIB_STUB=1 \
    bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/simple.flow.yaml" >/dev/null 2>&1
  [ -d "${BROWSER_SKILL_HOME}/captures/001" ] || fail "pre-stage: no captures/001 produced"
  # Mutate the OLD steps.jsonl: change first step's status to "error" so
  # replay (which produces fresh "ok" events) diverges.
  steps_log="${BROWSER_SKILL_HOME}/captures/001/steps.jsonl"
  tmp="${steps_log}.tmp"
  jq -c 'if .step_index == 0 then .status = "error" else . end' "${steps_log}" > "${tmp}"
  mv "${tmp}" "${steps_log}"
  chmod 600 "${steps_log}"

  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-replay.sh" 001 --strict
  [ "${status}" = "13" ] || fail "expected EXIT_ASSERTION_FAILED (13) under --strict on divergent replay; got ${status}"
}

@test "browser-replay.sh: --dry-run prints planned step list and exits 0; no new capture" {
  # Pre-stage.
  BROWSER_SKILL_LIB_STUB=1 \
    bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/simple.flow.yaml" >/dev/null 2>&1
  before_dirs="$(ls -d "${BROWSER_SKILL_HOME}/captures/"*/ 2>/dev/null | wc -l | tr -d ' ')"

  run bash "${SCRIPTS_DIR}/browser-replay.sh" 001 --dry-run
  assert_status 0
  assert_output_contains "dry-run"
  after_dirs="$(ls -d "${BROWSER_SKILL_HOME}/captures/"*/ 2>/dev/null | wc -l | tr -d ' ')"
  [ "${before_dirs}" = "${after_dirs}" ] || fail "--dry-run should not create new capture (was ${before_dirs}, now ${after_dirs})"
}

@test "browser-replay.sh: rejects non-flow captures (e.g. snapshot) with helpful message" {
  # Hand-craft a capture dir for a non-flow verb.
  mkdir -p "${BROWSER_SKILL_HOME}/captures/099"
  chmod 700 "${BROWSER_SKILL_HOME}/captures/099"
  jq -nc '{capture_id: "099", verb: "snapshot", schema_version: 1, status: "ok"}' \
    > "${BROWSER_SKILL_HOME}/captures/099/meta.json"
  chmod 600 "${BROWSER_SKILL_HOME}/captures/099/meta.json"

  run bash "${SCRIPTS_DIR}/browser-replay.sh" 099
  [ "${status}" -ne 0 ] || fail "expected non-zero exit for non-flow capture; got 0"
  assert_output_contains "not a flow capture"
}

@test "browser-replay.sh: emits per-step replay_diff event lines on stdout" {
  # Pre-stage.
  BROWSER_SKILL_LIB_STUB=1 \
    bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/simple.flow.yaml" >/dev/null 2>&1

  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-replay.sh" 001
  assert_status 0
  # 3 step-level replay_diff events (simple.flow.yaml has 3 steps).
  diff_count="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(.event=="replay_diff")) | length')"
  [ "${diff_count}" = "3" ] || fail "expected 3 replay_diff events, got ${diff_count}"
  # 1 replay_diff_summary event.
  summary_count="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(.event=="replay_diff_summary")) | length')"
  [ "${summary_count}" = "1" ] || fail "expected 1 replay_diff_summary event, got ${summary_count}"
}
