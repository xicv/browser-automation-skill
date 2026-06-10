#!/usr/bin/env bats
# Proves the persistent-CDP shared-browser mechanic: the daemon exposes a real
# CDP endpoint, and an INDEPENDENT client (connectOverCDP — proxy for
# chrome-devtools-mcp --browser-url) attaches to the SAME page the daemon opened.
# Gated on real Playwright; CI without it skips the whole file.

load helpers

setup_file() {
  if ! command -v playwright >/dev/null 2>&1; then
    skip "playwright binary not on PATH — run: npm i -g playwright @playwright/test && playwright install chromium"
  fi
}

setup() {
  cd "${BATS_TEST_DIRNAME}/.." || return 1
  # Isolate browser-skill state in a temp home (preserve real HOME so Playwright's
  # cached chromium at ~/Library/Caches/ms-playwright resolves).
  local real_home="${HOME}"
  setup_temp_home
  HOME="${real_home}"
  export HOME
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  node scripts/lib/node/playwright-driver.mjs daemon-stop >/dev/null 2>&1 || true
}

teardown() {
  node scripts/lib/node/playwright-driver.mjs daemon-stop >/dev/null 2>&1 || true
  teardown_temp_home
}

@test "cdp shared-browser: daemon-started state exposes a reachable cdp_endpoint" {
  run node scripts/lib/node/playwright-driver.mjs daemon-start
  [ "${status}" -eq 0 ]
  printf '%s' "${output}" | jq -e '.event == "daemon-started" and (.cdp_endpoint | startswith("http://127.0.0.1:"))' >/dev/null
  local endpoint
  endpoint="$(printf '%s' "${output}" | jq -r '.cdp_endpoint')"
  run curl -s "${endpoint}/json/version"
  [ "${status}" -eq 0 ]
  printf '%s' "${output}" | jq -e 'has("Browser")' >/dev/null
}

@test "cdp shared-browser: second CDP client sees the page the daemon opened (cross-adapter proxy)" {
  run node scripts/lib/node/playwright-driver.mjs daemon-start
  [ "${status}" -eq 0 ]
  local endpoint
  endpoint="$(printf '%s' "${output}" | jq -r '.cdp_endpoint')"

  run node scripts/lib/node/playwright-driver.mjs open --url https://example.com
  [ "${status}" -eq 0 ]
  printf '%s' "${output}" | jq -e '.attached_to_daemon == true and .url == "https://example.com/"' >/dev/null

  # Independent client attaches over CDP and reads the same page title — proves
  # chrome-devtools-mcp --browser-url will hit the same live page.
  run node -e "
    const { execSync } = require('node:child_process');
    const { createRequire } = require('node:module');
    const { join } = require('node:path');
    const npmRoot = execSync('npm root -g', { encoding: 'utf-8' }).trim();
    const req = createRequire(join(npmRoot, 'x.js'));
    const { chromium } = req('playwright');
    (async () => {
      const b = await chromium.connectOverCDP('${endpoint}');
      const ctx = b.contexts()[0];
      const page = ctx.pages().find(p => p.url().includes('example.com')) || ctx.pages()[0];
      const title = await page.evaluate(() => document.title);
      console.log(JSON.stringify({ url: page.url(), title }));
      await b.close();
    })().catch(e => { console.error(e.message); process.exit(1); });
  "
  [ "${status}" -eq 0 ]
  printf '%s' "${output}" | tail -1 | jq -e '(.url | contains("example.com")) and (.title | length > 0)' >/dev/null
}
