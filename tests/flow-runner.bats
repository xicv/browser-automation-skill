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

@test "flow_parse: top-level site is emitted in _meta" {
  local flow_file="${TEST_HOME}/with-site.flow.yaml"
  printf '%s\n' \
    'name: with-site' \
    'site: app' \
    'session: task-1' \
    'steps:' \
    '  - snapshot: {}' \
    > "${flow_file}"

  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_parse '${flow_file}'
  "
  assert_status 0
  printf '%s\n' "${output}" | jq -e -s \
    'map(select(._kind=="meta")) | .[0].site == "app" and .[0].session == "task-1"' \
    >/dev/null
}

@test "browser-flow.sh (P1b): unsafe top-level site is rejected" {
  local flow_file="${TEST_HOME}/unsafe-site.flow.yaml"
  printf '%s\n' \
    'name: unsafe-site' \
    'site: ../app' \
    'session: task-1' \
    'steps:' \
    '  - snapshot: {}' \
    > "${flow_file}"

  run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${flow_file}" --check
  assert_status "${EXIT_USAGE_ERROR}"
  assert_output_contains "flow site"
}

@test "browser-flow.sh (P1b): unsafe top-level session is rejected" {
  local flow_file="${TEST_HOME}/unsafe-session.flow.yaml"
  printf '%s\n' \
    'name: unsafe-session' \
    'site: app' \
    'session: ../task-1' \
    'steps:' \
    '  - snapshot: {}' \
    > "${flow_file}"

  run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${flow_file}" --check
  assert_status "${EXIT_USAGE_ERROR}"
  assert_output_contains "flow session"
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

# --- Phase 9 part 1-ii: ${refs.NAME} resolution ---

@test "flow_apply_vars (9-1-ii): resolves \${refs.NAME} via global FLOW_REFS" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    declare -gA FLOW_VARS=()
    declare -gA FLOW_REFS=( [Email]=e3 [Submit]=e7 )
    step_in='{\"step_index\": 0, \"verb\": \"fill\", \"args\": {\"ref\": \"\${refs.Email}\", \"text\": \"x\"}}'
    flow_apply_vars \"\${step_in}\"
  "
  assert_status 0
  printf '%s' "${output}" | jq -e '.args.ref == "e3"' >/dev/null
}

@test "flow_apply_vars (9-1-ii): missing ref errors loudly with EXIT_USAGE_ERROR" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    declare -gA FLOW_VARS=()
    declare -gA FLOW_REFS=( [Email]=e3 )
    step_in='{\"step_index\": 0, \"verb\": \"click\", \"args\": {\"ref\": \"\${refs.GhostName}\"}}'
    flow_apply_vars \"\${step_in}\"
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "GhostName"
}

@test "flow_dispatch (9-1-ii): snapshot step extracts refs[] from event line into step.refs" {
  step_in='{"step_index": 0, "verb": "snapshot", "args": {}}'
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  BROWSER_SKILL_LIB_STUB=1 \
    run bash -c "
      source '${LIB_DIR}/common.sh'; init_paths
      source '${LIB_DIR}/flow.sh'
      flow_dispatch '${step_in}'
    "
  assert_status 0
  # step-event has .refs array.
  printf '%s' "${output}" | jq -e '.refs | type == "array" and length >= 1' >/dev/null \
    || fail "expected step-event to carry refs[] from snapshot event line; got: ${output}"
  # Stub fixture has Sign in → e2.
  printf '%s' "${output}" | jq -e '.refs | map(select(.text == "Sign in")) | length == 1' >/dev/null
}

@test "browser-flow.sh (9-1-ii): with-refs flow resolves \${refs.Sign in} via prior snapshot" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/with-refs.flow.yaml"
  assert_status 0
  capture_dir="$(ls -d "${BROWSER_SKILL_HOME}/captures/"*/ 2>/dev/null | head -1)"
  [ -d "${capture_dir}" ] || fail "no capture dir"
  # Step 1 (fill) should have args.ref resolved to e2 (the stub's "Sign in" → e2).
  step1="$(sed -n '2p' "${capture_dir}steps.jsonl")"
  printf '%s' "${step1}" | jq -e '.args.ref == "e2"' >/dev/null \
    || fail "expected step 1 args.ref resolved to e2; got: ${step1}"
}

@test "browser-flow.sh (9-1-ii): two snapshots → second replaces FLOW_REFS wholesale (latest-wins)" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/two-snapshots.flow.yaml"
  assert_status 0
  capture_dir="$(ls -d "${BROWSER_SKILL_HOME}/captures/"*/ 2>/dev/null | head -1)"
  # Both snapshot step events should carry refs[].
  step0_refs="$(jq -r 'select(.step_index==0) | .refs | length' "${capture_dir}steps.jsonl")"
  step1_refs="$(jq -r 'select(.step_index==1) | .refs | length' "${capture_dir}steps.jsonl")"
  [ "${step0_refs}" -ge 1 ] || fail "step 0 should carry refs[]; got: ${step0_refs}"
  [ "${step1_refs}" -ge 1 ] || fail "step 1 should carry refs[]; got: ${step1_refs}"
}

@test "browser-flow.sh (9-1-ii): missing-ref flow exits non-zero with helpful message" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/missing-ref.flow.yaml"
  [ "${status}" -ne 0 ] || fail "expected non-zero exit for missing ref; got 0"
  assert_output_contains "GhostName"
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

@test "flow_dispatch (P1b): top-level site/session become per-step globals" {
  local scripts_dir="${TEST_HOME}/flow-scripts"
  mkdir -p "${scripts_dir}"
  cat > "${scripts_dir}/browser-snapshot.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${BROWSER_SKILL_HOME}/snapshot-argv.log"
printf '%s\n' '{"verb":"snapshot","tool":"stub","why":"test","status":"ok"}'
STUB
  chmod +x "${scripts_dir}/browser-snapshot.sh"

  step_in='{"step_index": 0, "verb": "snapshot", "args": {}}'
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    export SCRIPTS_DIR='${scripts_dir}'
    source '${LIB_DIR}/flow.sh'
    FLOW_SITE=app
    FLOW_SESSION=task-1
    flow_dispatch '${step_in}'
  "
  assert_status 0
  printf '%s' "${output}" | jq -e '.args.site == "app" and .args.as == "task-1"' >/dev/null
  argv="$(tr '\n' ' ' < "${BROWSER_SKILL_HOME}/snapshot-argv.log")"
  case "${argv}" in
    *"--site app"*);;
    *) fail "expected --site app in argv, got: ${argv}" ;;
  esac
  case "${argv}" in
    *"--as task-1"*);;
    *) fail "expected --as task-1 in argv, got: ${argv}" ;;
  esac
}

@test "flow_dispatch (P1b): step-level site/as overrides flow defaults" {
  local scripts_dir="${TEST_HOME}/flow-scripts"
  mkdir -p "${scripts_dir}"
  cat > "${scripts_dir}/browser-snapshot.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${BROWSER_SKILL_HOME}/snapshot-argv.log"
printf '%s\n' '{"verb":"snapshot","tool":"stub","why":"test","status":"ok"}'
STUB
  chmod +x "${scripts_dir}/browser-snapshot.sh"

  step_in='{"step_index": 0, "verb": "snapshot", "args": {"site":"other","as":"other-session"}}'
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    export SCRIPTS_DIR='${scripts_dir}'
    source '${LIB_DIR}/flow.sh'
    FLOW_SITE=app
    FLOW_SESSION=task-1
    flow_dispatch '${step_in}'
  "
  assert_status 0
  printf '%s' "${output}" | jq -e '.args.site == "other" and .args.as == "other-session"' >/dev/null
  argv="$(tr '\n' ' ' < "${BROWSER_SKILL_HOME}/snapshot-argv.log")"
  case "${argv}" in
    *"--site other"*);;
    *) fail "expected --site other in argv, got: ${argv}" ;;
  esac
  case "${argv}" in
    *"--as other-session"*);;
    *) fail "expected --as other-session in argv, got: ${argv}" ;;
  esac
  case "${argv}" in
    *"task-1"*|*"--site app"*) fail "flow defaults should not override step args; got: ${argv}" ;;
  esac
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

@test "browser-flow.sh (P1b): top-level site/session resolves storageState for each step" {
  bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/site.sh'
    source '${LIB_DIR}/session.sh'
    site_save app '{\"schema_version\":1,\"name\":\"app\",\"url\":\"https://example.com\",\"label\":\"App\",\"default_session\":null,\"default_tool\":null,\"viewport\":{\"width\":1280,\"height\":720}}' '{}'
    session_save task-1 '{\"cookies\":[],\"origins\":[{\"origin\":\"https://example.com\",\"localStorage\":[]}]}' '{\"site\":\"app\",\"origin\":\"https://example.com\"}'
  "

  local flow_file="${TEST_HOME}/p1b-site-session.flow.yaml"
  printf '%s\n' \
    'name: p1b-site-session' \
    'site: app' \
    'session: task-1' \
    'steps:' \
    '  - snapshot: { dry-run: true }' \
    > "${flow_file}"

  run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${flow_file}"
  assert_status 0
  capture_dir="$(ls -d "${BROWSER_SKILL_HOME}/captures/"*/ 2>/dev/null | head -1)"
  [ -d "${capture_dir}" ] || fail "no capture dir created"
  step0="$(sed -n '1p' "${capture_dir}steps.jsonl")"
  printf '%s' "${step0}" | jq -e \
    '.args.site == "app" and .args.as == "task-1" and .args["dry-run"] == "true" and .status == "ok"' \
    >/dev/null || fail "expected resolved flow globals in step args; got: ${step0}"
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
