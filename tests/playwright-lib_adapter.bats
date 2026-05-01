load helpers

# Tests for the playwright-lib node-bridge driver in stub mode. Real mode
# (lazy-imports playwright) lands in a follow-up; the contract here is the
# argv-hash → fixture-lookup behavior that the bash adapter relies on.

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "playwright-lib driver: open --url returns canned navigate event from fixture" {
  BROWSER_SKILL_LIB_STUB=1 \
    run node scripts/lib/node/playwright-driver.mjs open --url https://example.com
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "navigate" and .url == "https://example.com"' >/dev/null
}

@test "playwright-lib driver: snapshot returns canned refs array" {
  BROWSER_SKILL_LIB_STUB=1 \
    run node scripts/lib/node/playwright-driver.mjs snapshot
  assert_status 0
  printf '%s' "${output}" | jq -e '.refs | length == 2' >/dev/null
}

@test "playwright-lib driver: click --ref e3 returns canned click event" {
  BROWSER_SKILL_LIB_STUB=1 \
    run node scripts/lib/node/playwright-driver.mjs click --ref e3
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "click" and .ref == "e3"' >/dev/null
}

@test "playwright-lib driver: missing fixture exits 41 with structured error" {
  BROWSER_SKILL_LIB_STUB=1 \
    run node scripts/lib/node/playwright-driver.mjs nope
  [ "${status}" = "41" ] || fail "expected EXIT_TOOL_UNSUPPORTED_OP (41), got ${status}"
  printf '%s' "${output}" | jq -e '.status == "error" and (.reason | startswith("no fixture"))' >/dev/null
}

@test "playwright-lib driver: STUB_LOG_FILE captures argv (one arg per line, ts-prefixed block)" {
  STUB_LOG_FILE="$(mktemp)"
  BROWSER_SKILL_LIB_STUB=1 \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run node scripts/lib/node/playwright-driver.mjs open --url https://example.com
  assert_status 0
  grep -q '^open$'                "${STUB_LOG_FILE}"
  grep -q '^--url$'               "${STUB_LOG_FILE}"
  grep -q '^https://example.com$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "playwright-lib driver: real mode (BROWSER_SKILL_LIB_STUB unset) errors with self-healing hint" {
  unset BROWSER_SKILL_LIB_STUB
  run node scripts/lib/node/playwright-driver.mjs open --url https://example.com
  [ "${status}" = "41" ] || fail "expected exit 41, got ${status}"
  echo "${output}" | grep -q "BROWSER_SKILL_LIB_STUB" || fail "expected self-healing hint"
}
