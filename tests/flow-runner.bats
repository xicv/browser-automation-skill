load helpers

# Phase 9 part 1-i — flow_run foundation tests.
# YAML subset (flat top-level + flow-style step bodies); ${var} templating;
# whole-flow capture (meta.json + steps.jsonl); per-step bash verb dispatch.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

# --- flow_parse ---

@test "flow_parse: 3-step happy-path emits _meta line + 3 step JSON lines" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_parse '${FIXTURES_DIR}/flows/simple.flow.yaml'
  "
  assert_status 0
  meta_count="$(printf '%s\n' "${output}" | jq -e -s 'map(select(._kind=="meta")) | length')"
  step_count="$(printf '%s\n' "${output}" | jq -e -s 'map(select(._kind=="step")) | length')"
  [ "${meta_count}" = "1" ] || fail "expected 1 _meta line, got ${meta_count}"
  [ "${step_count}" = "3" ] || fail "expected 3 step lines, got ${step_count}"
  # _meta carries name + session.
  printf '%s\n' "${output}" | jq -e -s 'map(select(._kind=="meta")) | .[0] | .name == "simple-three-step" and .session == "task-1"' >/dev/null
  # First step has correct shape.
  printf '%s\n' "${output}" | jq -e -s 'map(select(._kind=="step")) | .[0] | .step_index == 0 and .verb == "snapshot"' >/dev/null
}

@test "flow_parse: missing 'steps:' field exits EXIT_USAGE_ERROR" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_parse '${FIXTURES_DIR}/flows/missing-steps.flow.yaml'
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "missing required field 'steps'"
}

@test "flow_parse: missing 'name:' field exits EXIT_USAGE_ERROR" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_parse '${FIXTURES_DIR}/flows/missing-name.flow.yaml'
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "missing required field 'name'"
}

@test "flow_parse: with-vars fixture emits _meta with vars block + 3 step lines" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_parse '${FIXTURES_DIR}/flows/with-vars.flow.yaml'
  "
  assert_status 0
  # _meta.vars contains both keys.
  printf '%s\n' "${output}" | jq -e -s 'map(select(._kind=="meta")) | .[0].vars.url_path == "/users/new" and .[0].vars.user_email == "alice@example.com"' >/dev/null
  step_count="$(printf '%s\n' "${output}" | jq -e -s 'map(select(._kind=="step")) | length')"
  [ "${step_count}" = "3" ] || fail "expected 3 step lines, got ${step_count}"
}

# --- flow_apply_vars ---

@test "flow_apply_vars: substitutes \${var} in step args" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    declare -gA FLOW_VARS=(\\
      [url_path]=/users/new \\
      [user_email]=alice@example.com\\
    )
    step_in='{\"step_index\": 0, \"verb\": \"open\", \"args\": {\"url\": \"\${url_path}\"}}'
    flow_apply_vars \"\${step_in}\"
  "
  assert_status 0
  printf '%s' "${output}" | jq -e '.args.url == "/users/new"' >/dev/null
}

@test "flow_apply_vars: missing var exits EXIT_USAGE_ERROR" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    declare -gA FLOW_VARS=()
    step_in='{\"step_index\": 0, \"verb\": \"open\", \"args\": {\"url\": \"\${missing}\"}}'
    flow_apply_vars \"\${step_in}\"
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "undefined var"
}

@test "flow_apply_vars: leaves \${refs.NAME} literal (deferred to 9-1-ii)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    declare -gA FLOW_VARS=()
    step_in='{\"step_index\": 0, \"verb\": \"fill\", \"args\": {\"ref\": \"\${refs.Name}\", \"text\": \"x\"}}'
    flow_apply_vars \"\${step_in}\"
  "
  assert_status 0
  printf '%s' "${output}" | jq -e '.args.ref == "${refs.Name}"' >/dev/null
}

# --- flow_dispatch ---

@test "flow_dispatch: snapshot step invokes browser-snapshot.sh and captures the verb's summary line" {
  step_in='{"step_index": 0, "verb": "snapshot", "args": {}}'
  BROWSER_SKILL_LIB_STUB=1 \
    run bash -c "
      source '${LIB_DIR}/common.sh'; init_paths
      source '${LIB_DIR}/flow.sh'
      flow_dispatch '${step_in}'
    "
  assert_status 0
  # Output is a step-event JSON line.
  printf '%s' "${output}" | jq -e '.step_index == 0 and .verb == "snapshot"' >/dev/null
  # Summary line carried inside step-event.
  printf '%s' "${output}" | jq -e '.summary.verb == "snapshot"' >/dev/null
}

@test "flow_dispatch: unknown verb returns 41 (UNSUPPORTED_OP) in step-event status" {
  step_in='{"step_index": 0, "verb": "ghostverb", "args": {}}'
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_dispatch '${step_in}'
  "
  # flow_dispatch itself returns 0; the step-event records the failed exit_code.
  assert_status 0
  printf '%s' "${output}" | jq -e '.exit_code == 41 and .status == "error"' >/dev/null
}

# --- browser-flow.sh end-to-end ---

@test "browser-flow.sh: --dry-run prints planned step list and exits 0; no capture written" {
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/simple.flow.yaml" --dry-run
  assert_status 0
  assert_output_contains "dry-run"
  assert_output_contains "step_count"
  # Last line is the JSON summary.
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "flow" and .dry_run == true' >/dev/null
  # No captures dir created.
  [ ! -d "${BROWSER_SKILL_HOME}/captures" ] || fail "--dry-run should not create captures dir"
}

@test "browser-flow.sh: 3-step happy-path writes capture + steps.jsonl + status=ok" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/simple.flow.yaml"
  assert_status 0
  # Find the capture dir.
  capture_dir="$(ls -d "${BROWSER_SKILL_HOME}/captures/"*/ 2>/dev/null | head -1)"
  [ -d "${capture_dir}" ] || fail "no capture dir created"
  [ -f "${capture_dir}meta.json" ] || fail "meta.json missing"
  [ -f "${capture_dir}steps.jsonl" ] || fail "steps.jsonl missing"
  # meta.json shape.
  jq -e '.verb == "flow" and .flow_name == "simple-three-step" and .status == "ok"' "${capture_dir}meta.json" >/dev/null
  jq -e '.step_count == 3 and .successful_steps == 3 and .failed_steps == 0' "${capture_dir}meta.json" >/dev/null
  # steps.jsonl: 3 lines.
  step_count="$(wc -l < "${capture_dir}steps.jsonl" | tr -d ' ')"
  [ "${step_count}" = "3" ] || fail "expected 3 step lines in steps.jsonl, got ${step_count}"
}

@test "browser-flow.sh: --var override overrides vars: defaults" {
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/with-vars.flow.yaml" --dry-run --var url_path=/overridden
  assert_status 0
  # Dry-run plan output should contain the overridden value.
  assert_output_contains "/overridden"
  # Should NOT contain the original vars: default value (it was overridden).
  if printf '%s\n' "${output}" | grep -q '/users/new'; then
    fail "expected /users/new to be overridden by --var url_path=/overridden"
  fi
}
