load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

@test "browser-fill: --ref e3 --text hello translates to positional target+text at adapter boundary" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-fill.sh" --ref e3 --text hello
  assert_status 0
  grep -q '^fill$'   "${STUB_LOG_FILE}"
  grep -q '^e3$'     "${STUB_LOG_FILE}"
  grep -q '^hello$'  "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-fill: emits summary with verb=fill, ref=e3, status=ok (text path)" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-fill.sh" --ref e3 --text hello
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "fill" and .ref == "e3" and .status == "ok"' >/dev/null
}

# ---------- Phase 14 (Bundle #2): opt-in strict post-condition for fill ----------

@test "browser-fill: BROWSER_SKILL_STRICT_POSTCOND=0 default → no auto post-condition" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-fill.sh" --ref e3 --text hello
  assert_status 0
  local event
  event="$(tail -1 "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  printf '%s' "${event}" | jq -e '.post_condition_hit == null' >/dev/null \
    || fail "default should leave post_condition_hit null; event: ${event}"
}

@test "browser-fill: STRICT_POSTCOND=1 + text-not-in-response → oblivious_success" {
  # Stub fixture for `fill e3 hello` returns {"event":"fill","ref":"e3","status":"ok"}
  # — does NOT contain "hello". With strict mode, this is a true oblivious_success.
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  BROWSER_SKILL_STRICT_POSTCOND=1 \
    run bash "${SCRIPTS_DIR}/browser-fill.sh" --ref e3 --text hello
  assert_status 0
  local event
  event="$(tail -1 "${BROWSER_SKILL_HOME}/memory/stats.jsonl")"
  printf '%s' "${event}" | jq -e '.post_condition_target_type == "element_value"' >/dev/null \
    || fail "expected target_type=element_value; event: ${event}"
  printf '%s' "${event}" | jq -e '.failure_mode == "oblivious_success"' >/dev/null \
    || fail "expected oblivious_success (text not echoed in adapter response); event: ${event}"
}

@test "browser-fill: STRICT_POSTCOND=1 + --secret-stdin path → never auto-derives EXPECT_VALUE" {
  # --secret-stdin path returns 41 BEFORE telemetry, so we verify by argv:
  # the secret must never appear in EXPECT_VALUE even if STRICT mode is on.
  # We assert by inspecting that when --text IS used with STRICT, derived value
  # equals --text — but when --secret-stdin is used (no --text), derivation must
  # NOT pull from any secret source. AP-7 is the spec.
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  BROWSER_SKILL_STRICT_POSTCOND=1 \
    run bash -c "printf '%s' 'TOPSECRET' | bash '${SCRIPTS_DIR}/browser-fill.sh' --ref e3 --secret-stdin"
  # adapter returns 41 (no stdin-secret support in playwright-cli)
  [ "${status}" = "41" ] || fail "expected 41, got ${status}"
  # No stats event should reference the secret in EXPECT_VALUE.
  if [ -f "${BROWSER_SKILL_HOME}/memory/stats.jsonl" ]; then
    if grep -q "TOPSECRET" "${BROWSER_SKILL_HOME}/memory/stats.jsonl"; then
      fail "secret leaked into stats.jsonl"
    fi
  fi
}

@test "browser-fill: --secret-stdin returns 41 (playwright-cli has no stdin-secret mode; routed to playwright-lib in Phase 4)" {
  # The adapter rejects --secret-stdin BEFORE invoking the binary — this is the
  # correct behavior because playwright-cli only takes the secret as a positional
  # arg (which would leak it via argv, AP-7). Phase 4's playwright-lib adapter
  # reads stdin natively in Node, where it never reaches argv.
  STUB_LOG_FILE="$(mktemp)"
  local secret="hunter2-NEVER-IN-ARGV"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash -c "printf '%s' '${secret}' | bash '${SCRIPTS_DIR}/browser-fill.sh' --ref e3 --secret-stdin"
  [ "${status}" = "41" ] || fail "expected EXIT_TOOL_UNSUPPORTED_OP (41), got ${status}"
  # Argv-leak guard: even though adapter rejects, verify the secret never reached
  # the (would-be) binary. The stub log must be empty (binary never invoked) OR
  # if invoked must not contain the secret.
  if [ -s "${STUB_LOG_FILE}" ] && grep -q "${secret}" "${STUB_LOG_FILE}"; then
    rm -f "${STUB_LOG_FILE}"
    fail "secret leaked into argv log: ${STUB_LOG_FILE}"
  fi
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-fill: missing --ref fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-fill.sh" --text hello
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "ref"
}

@test "browser-fill: neither --text nor --secret-stdin fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-fill.sh" --ref e3
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "text"
}

@test "browser-fill: both --text and --secret-stdin supplied fails EXIT_USAGE_ERROR" {
  run bash -c "printf 'x' | bash '${SCRIPTS_DIR}/browser-fill.sh' --ref e3 --text hello --secret-stdin"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

# --- selector-mode plumbing (Phase 11 cache enabler — mirrors click precedent) ---

@test "browser-fill --selector: passes selector to adapter as target" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-fill.sh" \
      --tool=playwright-cli --selector 'input.email' --text alice@example.com
  # Stub records argv → fill / input.email / alice@example.com.
  grep -q '^fill$'              "${STUB_LOG_FILE}" || fail "stub did not record fill verb"
  grep -q '^input.email$'       "${STUB_LOG_FILE}" || fail "stub did not see selector as target"
  grep -q '^alice@example.com$' "${STUB_LOG_FILE}" || fail "stub did not see --text"
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-fill: --selector AND --ref fails EXIT_USAGE_ERROR (mutually exclusive)" {
  run bash "${SCRIPTS_DIR}/browser-fill.sh" --selector 'input.x' --ref e1 --text hi
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

@test "browser-fill: neither --selector nor --ref fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-fill.sh" --text hello
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "selector"
}
