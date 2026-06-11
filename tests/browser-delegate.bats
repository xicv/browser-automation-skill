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
  assert_output_contains 'task-file-runner'
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

@test "browser-delegate: task text is passed via private file, not runner argv" {
  local marker="SENSITIVE-TASK-CANARY-argv"
  local argv_log="${BROWSER_SKILL_HOME}/delegate-argv.log"
  BROWSER_DELEGATE_STUB_ARGV_LOG="${argv_log}" \
  BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "collect ${marker}" --start-url https://example.com --task-id argv1
  assert_status 0
  [ -f "${argv_log}" ] || fail "stub argv log missing"
  assert_output_contains "STUB-FINAL-ANSWER for: collect ${marker}"
  if grep -qF "${marker}" "${argv_log}"; then
    fail "task marker leaked through runner argv: $(cat "${argv_log}")"
  fi
  task_arg="$(sed -n '1p' "${argv_log}")"
  if [ -f "${task_arg}" ]; then
    fail "task file should be deleted after runner returns: ${task_arg}"
  fi
}

@test "browser-delegate: failed run withholds final_response" {
  STUB_EXIT=42 BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "failure path" --start-url https://example.com --task-id fail1
  assert_status "${EXIT_TOOL_CRASHED}"
  assert_output_contains '"_kind":"delegate_error"'
  assert_output_not_contains '"_kind":"delegate_result"'
  assert_output_not_contains 'final_response'
  assert_output_not_contains 'STUB-FINAL-ANSWER'
  last="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last}" | jq -e '.verb=="delegate" and .status=="error"' >/dev/null \
    || fail "summary wrong: ${last}"
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
  printf '%s' "${line}" | jq -e '.adapter_route=="browser-delegate" and .offloaded_input_tokens==1234 and .offloaded_output_tokens==56 and .delegate_steps==2 and .delegate_backend=="webwright" and .duration_ms >= 0 and .stdout_bytes > 0 and .stderr_bytes == 0' >/dev/null \
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
  jq -nc '{schema_version:1,name:"app",site:"app",account:"a@example.com",backend:"plaintext",created_at:"2026-06-11T00:00:00Z"}' \
    > "${BROWSER_SKILL_HOME}/credentials/app.json"
  BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "x" --start-url https://example.com --task-id cs1 --site app
  assert_status 28
  assert_output_contains 'NO-AUTH'
}

@test "browser-delegate: --site with legacy exact-name creds -> refused (exit 28)" {
  mkdir -p "${BROWSER_SKILL_HOME}/credentials"
  printf '{"backend":"plaintext"}\n' > "${BROWSER_SKILL_HOME}/credentials/app.json"
  BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "x" --start-url https://example.com --task-id cs1-legacy --site app
  assert_status 28
  assert_output_contains 'NO-AUTH'
}

@test "browser-delegate: --site with role-named stored creds -> refused (exit 28)" {
  mkdir -p "${BROWSER_SKILL_HOME}/credentials"
  jq -nc '{schema_version:1,name:"app--admin",site:"app",account:"a@example.com",backend:"plaintext",created_at:"2026-06-11T00:00:00Z"}' \
    > "${BROWSER_SKILL_HOME}/credentials/app--admin.json"
  BROWSER_DELEGATE_RUNNER_CMD="${RUNNER}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" \
      --task "x" --start-url https://example.com --task-id cs2 --site app
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

@test "browser-delegate config get: Webwright venv without key is unavailable" {
  ww="${BROWSER_SKILL_HOME}/fake-webwright"
  mkdir -p "${ww}/.venv/bin" "${BROWSER_SKILL_HOME}/empty-config"
  touch "${ww}/.venv/bin/activate"
  MSWEBA_GLOBAL_CONFIG_DIR="${BROWSER_SKILL_HOME}/empty-config" \
  BROWSER_SKILL_WEBWRIGHT_DIR="${ww}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" config get
  assert_status 0
  printf '%s\n' "${lines[@]}" | jq -se 'map(select(._kind=="delegate_policy"))[0].available == false' >/dev/null \
    || fail "expected available:false without ANTHROPIC_API_KEY; output: ${output}"
}

@test "browser-delegate config get: Webwright venv plus key is available" {
  ww="${BROWSER_SKILL_HOME}/fake-webwright"
  cfg="${BROWSER_SKILL_HOME}/webwright-config"
  mkdir -p "${ww}/.venv/bin" "${cfg}"
  touch "${ww}/.venv/bin/activate"
  printf 'ANTHROPIC_API_KEY=test-key\n' > "${cfg}/.env"
  chmod 600 "${cfg}/.env"
  MSWEBA_GLOBAL_CONFIG_DIR="${cfg}" \
  BROWSER_SKILL_WEBWRIGHT_DIR="${ww}" \
    run bash "${SCRIPTS_DIR}/browser-delegate.sh" config get
  assert_status 0
  printf '%s\n' "${lines[@]}" | jq -se 'map(select(._kind=="delegate_policy"))[0].available == true' >/dev/null \
    || fail "expected available:true with ANTHROPIC_API_KEY; output: ${output}"
}
