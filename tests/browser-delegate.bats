load helpers

# Phase 15 part 1 — browser-delegate verb (delegated agent loop, ship-dark).
# Uses a stub runner via BROWSER_DELEGATE_RUNNER_CMD; no real Webwright/GLM.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  RUNNER="${BATS_TEST_DIRNAME}/stubs/webwright-runner"
}
teardown() { teardown_temp_home; }

@test "browser-delegate --dry-run: prints command, spawns nothing" {
  run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
    --dry-run --task "do a thing" --start-url https://example.com --task-id dr1
  assert_status 0
  assert_output_contains '"_kind":"dry_run"'
  assert_output_contains 'webwright.run.cli'
  assert_output_contains 'example.com'
  [ ! -d "${BROWSER_SKILL_HOME}/delegate/dr1_stub" ] || fail "dry-run spawned a run dir"
  last="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last}" | jq -e '.verb=="delegate" and .status=="ok"' >/dev/null || fail "summary wrong: ${last}"
}

@test "browser-delegate: stub run -> exit 0 + offloaded tokens + compact result" {
  BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "scrape something" --start-url https://example.com --task-id ok1
  assert_status 0
  assert_output_contains 'STUB-FINAL-ANSWER'
  last="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last}" | jq -e '.verb=="delegate" and .status=="ok" and .offloaded_input_tokens==1234 and .offloaded_output_tokens==56 and .steps==2' >/dev/null \
    || fail "summary wrong: ${last}"
  assert_output_not_contains 'cumulative_response'
}

@test "browser-delegate: emits stats event with offloaded token fields" {
  BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "x" --start-url https://example.com --task-id st1
  assert_status 0
  stats="${BROWSER_SKILL_HOME}/memory/stats.jsonl"
  [ -f "${stats}" ] || fail "no stats.jsonl written"
  line="$(grep '"verb":"delegate"' "${stats}" | tail -1)"
  [ -n "${line}" ] || fail "no delegate event in stats.jsonl"
  printf '%s' "${line}" | jq -e '.adapter_route=="browser-delegate" and .offloaded_input_tokens==1234 and .offloaded_output_tokens==56 and .delegate_steps==2 and .delegate_backend=="webwright"' >/dev/null \
    || fail "stats event wrong: ${line}"
}

@test "browser-delegate: privacy canary in trajectory -> refused (exit 28), canary not surfaced" {
  STUB_INJECT_CANARY=1 BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "x" --start-url https://example.com --task-id cn1
  assert_status 28
  assert_output_not_contains 'PASSWORD-CANARY'
}

@test "browser-delegate: --site with stored creds -> refused (exit 28)" {
  mkdir -p "${BROWSER_SKILL_HOME}/credentials"
  printf '{"backend":"plaintext"}\n' > "${BROWSER_SKILL_HOME}/credentials/app.json"
  BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "x" --start-url https://example.com --task-id cs1 --site app
  assert_status 28
  assert_output_contains 'NO-AUTH'
}

@test "browser-delegate: missing --start-url -> exit 2" {
  run bash "${SCRIPTS_DIR}/browser-delegate.sh" --task "x"
  assert_status 2
}

@test "browser-delegate: Webwright absent -> exit 21 EXIT_TOOL_MISSING" {
  BROWSER_SKILL_WEBWRIGHT_DIR="${BROWSER_SKILL_HOME}/no-such-webwright" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "x" --start-url https://example.com --task-id nb1
  assert_status 21
}

@test "browser-delegate config get: default mode off, available false in clean env" {
  run bash "${SCRIPTS_DIR}/browser-delegate.sh" config get
  assert_status 0
  pol="$(printf '%s\n' "${lines[@]}" | jq -rs 'map(select(._kind=="delegate_policy"))[0] | "\(.mode) \(.available)"')"
  [ "${pol}" = "off false" ] || fail "expected 'off false'; got '${pol}' / output: ${output}"
}

@test "browser-delegate config set --mode auto: persists + merges, preserves other keys" {
  mkdir -p "${BROWSER_SKILL_HOME}"
  printf '{"capture":{"max_bytes":100}}\n' > "${BROWSER_SKILL_HOME}/config.json"
  run bash "${SCRIPTS_DIR}/browser-delegate.sh" config set --mode auto --min-steps 5
  assert_status 0
  cfg="${BROWSER_SKILL_HOME}/config.json"
  jq -e '.delegate.mode=="auto" and .delegate.min_steps==5 and .capture.max_bytes==100' "${cfg}" >/dev/null \
    || fail "config merge wrong: $(cat "${cfg}")"
}

@test "browser-delegate config set --mode bogus: usage error exit 2" {
  run bash "${SCRIPTS_DIR}/browser-delegate.sh" config set --mode bogus
  assert_status 2
}

@test "browser-delegate config get: available true under runner override" {
  BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" run bash "${SCRIPTS_DIR}/browser-delegate.sh" config get
  assert_status 0
  printf '%s\n' "${lines[@]}" | jq -se 'map(select(._kind=="delegate_policy"))[0].available == true' >/dev/null \
    || fail "expected available:true under runner override; output: ${output}"
}
