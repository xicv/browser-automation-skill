load helpers

# Phase 5 part 1e-i: new browser-extract.sh routes to chrome-devtools-mcp by
# default (post-1d router promotion). Existing fixture covers
# `extract --selector .title`.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "browser-extract: --selector .title routes to cdt-mcp via lib-stub fixture" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --selector .title
  assert_status 0
  printf '%s\n' "${lines[@]}" | grep -q '"event":"extract"' \
    || fail "expected extract event in output"
}

@test "browser-extract: emits summary with verb=extract, tool=chrome-devtools-mcp, status=ok" {
  BROWSER_SKILL_LIB_STUB=1 \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --selector .title
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "extract" and .tool == "chrome-devtools-mcp" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.selector == ".title"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.duration_ms | type == "number"' >/dev/null
}

@test "browser-extract: missing --selector AND --eval fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "selector"
}

@test "browser-extract: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool ghost-tool --selector .title
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-extract: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh" --dry-run --selector .title
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "extract" and .dry_run == true' >/dev/null
}

@test "browser-extract: --tool=playwright-cli fails (capability filter rejects extract)" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool playwright-cli --selector .title
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

# --- Phase 8 part 1-ii: --scrape end-to-end via obscura adapter ---

@test "browser-extract (8-1-ii): --tool obscura --scrape --eval EXPR url1 url2 url3 emits 3 events + ok summary" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool obscura --scrape \
      --eval document.title https://example.com https://example.org https://example.net
  assert_status 0
  evt_count="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(.event=="scrape_url")) | length')"
  [ "${evt_count}" = "3" ] || fail "expected 3 scrape_url events, got ${evt_count}"
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "extract" and .tool == "obscura" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.mode == "scrape" and .total_urls == 3 and .successful == 3 and .failed == 0' >/dev/null
}

@test "browser-extract (8-1-ii): --scrape with mixed results → status=partial" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool obscura --scrape \
      --eval document.title https://a.example.com https://b.example.com https://c.example.com
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.status == "partial" and .successful == 2 and .failed == 1' >/dev/null
}

@test "browser-extract (8-1-ii): --scrape with no URLs fails EXIT_USAGE_ERROR" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool obscura --scrape --eval document.title
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--scrape requires at least one URL"
}

@test "browser-extract (8-1-ii): --scrape --dry-run prints plan with mode=scrape and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh" --dry-run --scrape \
    --eval document.title https://example.com https://example.org
  assert_status 0
  assert_output_contains "dry-run"
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.mode == "scrape" and .total_urls == 2 and .dry_run == true' >/dev/null
}

# --- Phase 8 part 1-iii: --stealth end-to-end via obscura adapter ---

@test "browser-extract (8-1-iii): --tool obscura --stealth --eval EXPR <url> emits 1 event + ok summary" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool obscura --stealth \
      --eval document.title https://example.com
  assert_status 0
  evt_count="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(.event=="extract_stealth")) | length')"
  [ "${evt_count}" = "1" ] || fail "expected 1 extract_stealth event, got ${evt_count}"
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "extract" and .tool == "obscura" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.mode == "stealth" and .url == "https://example.com"' >/dev/null
}

@test "browser-extract (8-1-iii): --stealth without URL fails EXIT_USAGE_ERROR" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool obscura --stealth --eval document.title
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--stealth requires exactly one URL"
}

@test "browser-extract (8-1-iii): --stealth without --eval fails EXIT_USAGE_ERROR" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool obscura --stealth https://example.com
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--stealth requires --eval"
}

@test "browser-extract (8-1-iii): --scrape + --stealth fails EXIT_USAGE_ERROR (mutually exclusive)" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --tool obscura --scrape --stealth \
      --eval document.title https://example.com
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "mutually exclusive"
}

@test "browser-extract (8-1-iii): --stealth --dry-run prints plan with mode=stealth + url and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-extract.sh" --dry-run --stealth \
    --eval document.title https://example.com
  assert_status 0
  assert_output_contains "dry-run"
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.mode == "stealth" and .url == "https://example.com" and .dry_run == true' >/dev/null
}

# --- Phase 8 part 2-i: auto-routing (no --tool obscura needed) ---

@test "browser-extract (8-2-i): --scrape auto-routes to obscura (no --tool flag needed)" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --scrape \
      --eval document.title https://example.com https://example.org https://example.net
  assert_status 0
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.tool == "obscura" and .status == "ok" and .mode == "scrape"' >/dev/null
}

@test "browser-extract (8-2-i): --stealth auto-routes to obscura (no --tool flag needed)" {
  OBSCURA_BIN="${STUBS_DIR}/obscura" \
  OBSCURA_FIXTURES_DIR="${FIXTURES_DIR}/obscura" \
    run bash "${SCRIPTS_DIR}/browser-extract.sh" --stealth \
      --eval document.title https://example.com
  assert_status 0
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.tool == "obscura" and .status == "ok" and .mode == "stealth"' >/dev/null
}
