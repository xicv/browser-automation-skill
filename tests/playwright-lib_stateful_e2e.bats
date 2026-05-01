load helpers

# E2E for the IPC daemon chain: daemon-start → open → snapshot → click → stop.
# Gated on real Playwright being installed; CI without Playwright skips via
# setup_file().

setup_file() {
  if ! command -v playwright >/dev/null 2>&1; then
    skip "playwright binary not on PATH — run: npm i -g playwright @playwright/test && playwright install chromium"
  fi
}

setup() {
  # Preserve real $HOME so Playwright finds its chromium cache.
  local real_home="${HOME}"
  setup_temp_home
  HOME="${real_home}"
  export HOME
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}

teardown() {
  node scripts/lib/node/playwright-driver.mjs daemon-stop >/dev/null 2>&1 || true
  teardown_temp_home
}

@test "stateful e2e: full chain — start → open → snapshot → click → stop" {
  node scripts/lib/node/playwright-driver.mjs daemon-start >/dev/null
  run node scripts/lib/node/playwright-driver.mjs open --url https://example.com
  assert_status 0
  printf '%s' "${output}" | jq -e '.attached_to_daemon == true and .url == "https://example.com/"' >/dev/null

  run node scripts/lib/node/playwright-driver.mjs snapshot
  assert_status 0
  # First line is the JSON summary; subsequent lines are eN listings.
  local first
  first="$(printf '%s\n' "${lines[@]}" | head -1)"
  printf '%s' "${first}" | jq -e '.event == "snapshot" and .ref_count >= 1' >/dev/null
  # At least one ref line with eN prefix follows the JSON.
  printf '%s\n' "${lines[@]}" | grep -qE '^e[0-9]+ ' || fail "expected eN ref lines after snapshot summary"

  # Pick the first ref's id and click it.
  local first_ref
  first_ref="$(printf '%s\n' "${lines[@]}" | grep -m1 -oE '^e[0-9]+')"
  [ -n "${first_ref}" ] || fail "no eN ref found in snapshot output"

  run node scripts/lib/node/playwright-driver.mjs click --ref "${first_ref}"
  assert_status 0
  printf '%s' "${output}" | jq -e --arg r "${first_ref}" '.event == "click" and .ref == $r and .status == "ok"' >/dev/null
}

@test "stateful e2e: snapshot without prior open returns daemon error event" {
  node scripts/lib/node/playwright-driver.mjs daemon-start >/dev/null
  run node scripts/lib/node/playwright-driver.mjs snapshot
  printf '%s' "${output}" | jq -e '.event == "error" and (.message | contains("no open page"))' >/dev/null
}

@test "stateful e2e: click ref not in last snapshot returns ref-not-found error" {
  node scripts/lib/node/playwright-driver.mjs daemon-start >/dev/null
  node scripts/lib/node/playwright-driver.mjs open --url https://example.com >/dev/null
  node scripts/lib/node/playwright-driver.mjs snapshot >/dev/null
  run node scripts/lib/node/playwright-driver.mjs click --ref e999
  printf '%s' "${output}" | jq -e '.event == "error" and (.message | contains("e999"))' >/dev/null
}

@test "stateful e2e: fill --secret-stdin pipes secret to daemon (text never echoed in reply)" {
  node scripts/lib/node/playwright-driver.mjs daemon-start >/dev/null
  node scripts/lib/node/playwright-driver.mjs open --url https://example.com >/dev/null
  node scripts/lib/node/playwright-driver.mjs snapshot >/dev/null
  # example.com has no input fields; fill against e1 (a heading) will fail at
  # Playwright level, but we're testing the transport — secret should not appear
  # in the reply regardless. Capture both stdout + stderr to scan thoroughly.
  local secret="my-NEVER-IN-REPLY-secret-42"
  run bash -c "printf '%s' '${secret}' | node scripts/lib/node/playwright-driver.mjs fill --ref e1 --secret-stdin"
  if echo "${output}" | grep -q "${secret}"; then
    fail "secret leaked into client reply: ${output}"
  fi
}
