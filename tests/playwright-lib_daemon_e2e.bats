load helpers

# E2E tests for the playwright-lib daemon lifecycle. Gated on real Playwright
# being installed because they actually launch chromium. CI without Playwright
# (default) skips the whole file via the suite-wide skip in setup_file().

setup_file() {
  if ! command -v playwright >/dev/null 2>&1; then
    skip "playwright binary not on PATH — run: npm i -g playwright @playwright/test && playwright install chromium"
  fi
}

setup() {
  # Save real HOME — setup_temp_home overrides it, but Playwright caches the
  # chromium binary at ~/Library/Caches/ms-playwright/. Without the real HOME,
  # the daemon child fails with "Executable doesn't exist".
  local real_home="${HOME}"
  setup_temp_home
  HOME="${real_home}"
  export HOME
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}

teardown() {
  # Always ensure the daemon is stopped, even on test failure.
  node scripts/lib/node/playwright-driver.mjs daemon-stop >/dev/null 2>&1 || true
  teardown_temp_home
}

@test "daemon e2e: start → status → stop lifecycle" {
  run node scripts/lib/node/playwright-driver.mjs daemon-status
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-not-running"' >/dev/null

  run node scripts/lib/node/playwright-driver.mjs daemon-start
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-started" and (.pid | type == "number") and (.ws_endpoint | startswith("ws://"))' >/dev/null

  run node scripts/lib/node/playwright-driver.mjs daemon-status
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-running"' >/dev/null

  run node scripts/lib/node/playwright-driver.mjs daemon-stop
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-stopped"' >/dev/null

  run node scripts/lib/node/playwright-driver.mjs daemon-status
  printf '%s' "${output}" | jq -e '.event == "daemon-not-running"' >/dev/null
}

@test "daemon e2e: open attaches to running daemon (attached_to_daemon: true)" {
  node scripts/lib/node/playwright-driver.mjs daemon-start >/dev/null
  run node scripts/lib/node/playwright-driver.mjs open --url https://example.com
  assert_status 0
  printf '%s' "${output}" | jq -e '.attached_to_daemon == true and .url == "https://example.com/"' >/dev/null
}

@test "daemon e2e: open without daemon falls back to one-shot (attached_to_daemon: false)" {
  run node scripts/lib/node/playwright-driver.mjs open --url https://example.com
  assert_status 0
  printf '%s' "${output}" | jq -e '.attached_to_daemon == false and .url == "https://example.com/"' >/dev/null
}

@test "daemon e2e: starting a daemon when one is running is idempotent" {
  node scripts/lib/node/playwright-driver.mjs daemon-start >/dev/null
  run node scripts/lib/node/playwright-driver.mjs daemon-start
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-already-running"' >/dev/null
}

@test "daemon e2e: stopping when none running is a no-op success" {
  run node scripts/lib/node/playwright-driver.mjs daemon-stop
  assert_status 0
  printf '%s' "${output}" | jq -e '.event == "daemon-not-running"' >/dev/null
}
