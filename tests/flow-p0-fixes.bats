load helpers

# P0 flow-runner fixes — tests written FIRST (TDD).
#
# Fix 1 (P0c): js-yaml-backed flow_parse — CSS attribute selectors with inner
#              escaped quotes in YAML double-quoted strings, e.g.:
#                selector: "input[name=\"qual_file\"]"
#              The hand-rolled parser doesn't unescape \" → " inside double-
#              quoted YAML strings; js-yaml handles this correctly.
#
# Fix 2 (P0b): pre-flight verb validation, abort-on-first-failure default,
#              --continue-on-error, --check flags.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

# ---------------------------------------------------------------------------
# Fix 1 — YAML double-quoted string with escaped inner quotes
# ---------------------------------------------------------------------------

@test "flow_parse (P0c): YAML double-quoted selector with inner escaped quotes round-trips" {
  # YAML file has: selector: "input[name=\"qual_file\"]"
  # The hand-rolled parser leaves \" literal; js-yaml correctly unescapes to "
  local flow_file="${TEST_HOME}/attr-escaped.flow.yaml"
  # Write a file where the YAML value is double-quoted with \" escapes inside
  printf '%s\n' \
    'name: attr-escaped-test' \
    'steps:' \
    '  - fill: { selector: "input[name=\"qual_file\"]", text: hello }' \
    > "${flow_file}"
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_parse '${flow_file}'
  "
  assert_status 0
  step_line="$(printf '%s\n' "${output}" | jq -c 'select(._kind=="step")')"
  # After correct YAML parsing, selector must be: input[name="qual_file"] (no backslashes)
  printf '%s' "${step_line}" | jq -e '.args.selector == "input[name=\"qual_file\"]"' >/dev/null \
    || fail "selector not correctly unescaped: $(printf '%s' "${step_line}" | jq -r '.args.selector // "MISSING"')"
  printf '%s' "${step_line}" | jq -e '.args.text == "hello"' >/dev/null \
    || fail "text arg missing or wrong: ${step_line}"
}

@test "flow_parse (P0c): YAML double-quoted tr[data-id] selector with inner escaped quotes" {
  local flow_file="${TEST_HOME}/attr-tr.flow.yaml"
  printf '%s\n' \
    'name: attr-tr-test' \
    'steps:' \
    '  - click: { selector: "tr[data-id=\"769\"]" }' \
    > "${flow_file}"
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    flow_parse '${flow_file}'
  "
  assert_status 0
  step_line="$(printf '%s\n' "${output}" | jq -c 'select(._kind=="step")')"
  # Must produce: tr[data-id="769"]  (literal double-quotes, no backslashes)
  printf '%s' "${step_line}" | jq -e '.args.selector == "tr[data-id=\"769\"]"' >/dev/null \
    || fail "selector not correctly unescaped: $(printf '%s' "${step_line}" | jq -r '.args.selector // "MISSING"')"
}

@test "flow-parse.mjs: YAML escaped-quote selector round-trips via node directly" {
  local flow_file="${TEST_HOME}/attr-node.flow.yaml"
  printf '%s\n' \
    'name: attr-node-test' \
    'steps:' \
    '  - click: { selector: "tr[data-id=\"769\"]" }' \
    > "${flow_file}"
  run node "${SCRIPTS_DIR}/lib/node/flow-parse.mjs" "${flow_file}"
  assert_status 0
  step_line="$(printf '%s\n' "${output}" | jq -c 'select(._kind=="step")')"
  printf '%s' "${step_line}" | jq -e '.args.selector == "tr[data-id=\"769\"]"' >/dev/null \
    || fail "selector mangled in node output: $(printf '%s' "${step_line}" | jq -r '.args.selector // "MISSING"')"
}

@test "flow-parse.mjs: emits _meta + step lines with correct shape" {
  run node "${SCRIPTS_DIR}/lib/node/flow-parse.mjs" \
    "${FIXTURES_DIR}/flows/simple.flow.yaml"
  assert_status 0
  meta_count="$(printf '%s\n' "${output}" | jq -s 'map(select(._kind=="meta")) | length')"
  step_count="$(printf '%s\n' "${output}" | jq -s 'map(select(._kind=="step")) | length')"
  [ "${meta_count}" = "1" ] || fail "expected 1 _meta line, got ${meta_count}"
  [ "${step_count}" = "3" ] || fail "expected 3 step lines, got ${step_count}"
  printf '%s\n' "${output}" | jq -e -s \
    'map(select(._kind=="meta")) | .[0] | .name == "simple-three-step" and .session == "task-1"' \
    >/dev/null
}

@test "flow-parse.mjs: with-vars fixture emits vars in _meta" {
  run node "${SCRIPTS_DIR}/lib/node/flow-parse.mjs" \
    "${FIXTURES_DIR}/flows/with-vars.flow.yaml"
  assert_status 0
  printf '%s\n' "${output}" | jq -e -s \
    'map(select(._kind=="meta")) | .[0].vars.url_path == "/users/new" and .[0].vars.user_email == "alice@example.com"' \
    >/dev/null
}

@test "flow-parse.mjs: missing name field exits 2 with message" {
  run node "${SCRIPTS_DIR}/lib/node/flow-parse.mjs" \
    "${FIXTURES_DIR}/flows/missing-name.flow.yaml"
  assert_status 2
  assert_output_contains "name"
}

@test "flow-parse.mjs: missing steps field exits 2 with message" {
  run node "${SCRIPTS_DIR}/lib/node/flow-parse.mjs" \
    "${FIXTURES_DIR}/flows/missing-steps.flow.yaml"
  assert_status 2
  assert_output_contains "steps"
}

@test "flow-parse.mjs: dry-run boolean preserved as JSON boolean true" {
  run node "${SCRIPTS_DIR}/lib/node/flow-parse.mjs" \
    "${FIXTURES_DIR}/flows/simple.flow.yaml"
  assert_status 0
  # simple.flow.yaml has { dry-run: true } — must be boolean true not string "true"
  step_line="$(printf '%s\n' "${output}" | jq -c 'select(._kind=="step") | select(.step_index==0)')"
  printf '%s' "${step_line}" | jq -e '.args["dry-run"] == true' >/dev/null \
    || fail "dry-run should be boolean true; got: ${step_line}"
}

# ---------------------------------------------------------------------------
# Fix 2a — pre-flight verb validation
# ---------------------------------------------------------------------------

@test "browser-flow.sh (P0b): unknown verb exits EXIT_USAGE_ERROR before step 1" {
  local flow_file="${TEST_HOME}/bad-verb.flow.yaml"
  printf '%s\n' \
    'name: bad-verb-test' \
    'steps:' \
    '  - frobnicate: { selector: .foo }' \
    '  - snapshot: {}' \
    > "${flow_file}"
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${flow_file}"
  assert_status "${EXIT_USAGE_ERROR}"
  assert_output_contains "frobnicate"
  assert_output_contains "preflight"
  # No capture dir — browser must not have launched
  [ ! -d "${BROWSER_SKILL_HOME}/captures" ] \
    || fail "captures dir should not exist on preflight failure"
}

@test "browser-flow.sh (P0b): unknown verb error message lists known verbs" {
  local flow_file="${TEST_HOME}/bad-verb2.flow.yaml"
  printf '%s\n' \
    'name: bad-verb2-test' \
    'steps:' \
    '  - frobnicate: {}' \
    > "${flow_file}"
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${flow_file}"
  assert_status "${EXIT_USAGE_ERROR}"
  # At least one real verb must appear in the valid-verb list
  assert_output_contains "snapshot"
}

@test "browser-flow.sh (P0b): preflight reports correct step index for bad verb at index 1" {
  local flow_file="${TEST_HOME}/bad-verb3.flow.yaml"
  printf '%s\n' \
    'name: bad-verb3-test' \
    'steps:' \
    '  - snapshot: {}' \
    '  - frobnicate: {}' \
    > "${flow_file}"
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${flow_file}"
  assert_status "${EXIT_USAGE_ERROR}"
  assert_output_contains "frobnicate"
  # step_index 1 should appear in the error message
  assert_output_contains "1"
}

# ---------------------------------------------------------------------------
# Fix 2b — abort-on-first-failure default + --continue-on-error
# ---------------------------------------------------------------------------

@test "browser-flow.sh (P0b): --continue-on-error flag is accepted without error" {
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run \
    "${FIXTURES_DIR}/flows/simple.flow.yaml" --dry-run --continue-on-error
  assert_status 0
}

@test "browser-flow.sh (P0b): truly unknown flag still rejected" {
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run \
    "${FIXTURES_DIR}/flows/simple.flow.yaml" --totally-unknown-flag
  assert_status "${EXIT_USAGE_ERROR}"
}

# ---------------------------------------------------------------------------
# Fix 2c — --check flag
# ---------------------------------------------------------------------------

@test "browser-flow.sh (P0b): --check exits 0 with step plan, no capture" {
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run \
    "${FIXTURES_DIR}/flows/simple.flow.yaml" --check
  assert_status 0
  assert_output_contains '"_kind":"step"'
  [ ! -d "${BROWSER_SKILL_HOME}/captures" ] \
    || fail "--check should not create captures dir"
}

@test "browser-flow.sh (P0b): --check prints flow summary line as last line" {
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run \
    "${FIXTURES_DIR}/flows/simple.flow.yaml" --check
  assert_status 0
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "flow"' >/dev/null \
    || fail "expected flow summary as last line; got: ${last_line}"
}

@test "browser-flow.sh (P0b): --check with unknown verb exits EXIT_USAGE_ERROR (preflight runs)" {
  local flow_file="${TEST_HOME}/check-bad-verb.flow.yaml"
  printf '%s\n' \
    'name: check-bad-verb-test' \
    'steps:' \
    '  - frobnicate: {}' \
    > "${flow_file}"
  run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${flow_file}" --check
  assert_status "${EXIT_USAGE_ERROR}"
  assert_output_contains "frobnicate"
}

# ---------------------------------------------------------------------------
# Fix 2d — abort-on-first-failure and --continue-on-error behavioral tests
# (written to FAIL without the abort logic in browser-flow.sh)
# ---------------------------------------------------------------------------

@test "browser-flow.sh (P0b): default run — step 1 fails → only 1 step event in steps.jsonl, final status error" {
  # BROWSER_SKILL_LIB_STUB=1 makes the playwright-driver stub return an error
  # for any verb with no matching fixture hash (exit 41). A 2-step flow where
  # both steps would be executed without abort logic but only 1 should run with it.
  local flow_file="${TEST_HOME}/abort-test.flow.yaml"
  printf '%s\n' \
    'name: abort-test' \
    'steps:' \
    '  - snapshot: {}' \
    '  - snapshot: {}' \
    > "${flow_file}"
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${flow_file}"
  # Flow must exit non-zero (step 0 failed).
  [ "${status}" -ne 0 ] || fail "expected non-zero exit when step fails; got 0"
  # Exactly 1 step event written (abort after step 0).
  local capture_dir
  capture_dir="$(ls -d "${BROWSER_SKILL_HOME}/captures/"*/ 2>/dev/null | head -1)"
  [ -d "${capture_dir}" ] || fail "no capture dir created"
  local step_count
  step_count="$(jq -s 'length' "${capture_dir}steps.jsonl" 2>/dev/null || printf '0')"
  [ "${step_count}" = "1" ] \
    || fail "expected 1 step event (abort after first failure); got ${step_count}"
  # Final status must be 'error'.
  jq -e '.status == "error"' "${capture_dir}steps.jsonl" >/dev/null \
    || fail "expected step event status=error; content: $(cat "${capture_dir}steps.jsonl")"
}

@test "browser-flow.sh (P0b): --continue-on-error — step 1 fails → both steps execute (2 events)" {
  local flow_file="${TEST_HOME}/continue-test.flow.yaml"
  printf '%s\n' \
    'name: continue-test' \
    'steps:' \
    '  - snapshot: {}' \
    '  - snapshot: {}' \
    > "${flow_file}"
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-flow.sh" run "${flow_file}" --continue-on-error
  # Both steps must have been attempted regardless of failure.
  local capture_dir
  capture_dir="$(ls -d "${BROWSER_SKILL_HOME}/captures/"*/ 2>/dev/null | head -1)"
  [ -d "${capture_dir}" ] || fail "no capture dir created"
  local step_count
  step_count="$(jq -s 'length' "${capture_dir}steps.jsonl" 2>/dev/null || printf '0')"
  [ "${step_count}" = "2" ] \
    || fail "expected 2 step events (continue-on-error); got ${step_count}"
}
