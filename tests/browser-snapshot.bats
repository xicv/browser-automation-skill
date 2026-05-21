bats_require_minimum_version 1.5.0

load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

@test "browser-snapshot: passes 'snapshot' through to picked adapter via stub" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  assert_status 0
  grep -q '^snapshot$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-snapshot: emits summary with verb=snapshot, tool=playwright-cli, status=ok" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "snapshot" and .tool == "playwright-cli" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.duration_ms | type == "number"' >/dev/null
}

@test "browser-snapshot: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --tool ghost-tool
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-snapshot: --dry-run prints planned action and skips adapter" {
  run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --dry-run
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.status == "ok" and .dry_run == true' >/dev/null
}

# ---------- Phase 7 part 1-i: --capture wire-up ----------

@test "browser-snapshot --capture: writes captures/001/snapshot.json + meta.json + summary has capture_id" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --capture
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/captures/001/snapshot.json" ] || fail "snapshot.json not written"
  [ -f "${BROWSER_SKILL_HOME}/captures/001/meta.json" ]     || fail "meta.json not written"
  jq -e '.status == "ok"'                  "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
  jq -e '.verb == "snapshot"'              "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.capture_id == "001"' >/dev/null
}

@test "browser-snapshot --capture: dir mode 0700, meta.json mode 0600" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --capture
  assert_status 0
  dir_perms="$(stat -c '%a' "${BROWSER_SKILL_HOME}/captures/001" 2>/dev/null || stat -f '%Lp' "${BROWSER_SKILL_HOME}/captures/001" 2>/dev/null)"
  meta_perms="$(stat -c '%a' "${BROWSER_SKILL_HOME}/captures/001/meta.json" 2>/dev/null || stat -f '%Lp' "${BROWSER_SKILL_HOME}/captures/001/meta.json" 2>/dev/null)"
  [ "${dir_perms}" = "700" ]  || fail "expected dir mode 700, got ${dir_perms}"
  [ "${meta_perms}" = "600" ] || fail "expected meta mode 600, got ${meta_perms}"
}

@test "browser-snapshot --capture: _index.json updated after capture" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh" --capture
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/captures/_index.json" ] || fail "_index.json not written"
  jq -e '.latest == "001"'  "${BROWSER_SKILL_HOME}/captures/_index.json" >/dev/null
  jq -e '.count == 1'       "${BROWSER_SKILL_HOME}/captures/_index.json" >/dev/null
}

@test "browser-snapshot (no --capture): captures dir not created (clean state)" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  assert_status 0
  [ ! -d "${BROWSER_SKILL_HOME}/captures" ] || fail "captures dir created without --capture flag"
}

@test "browser-snapshot --capture: adapter failure → meta.json status=error (still finalized)" {
  # Force failure by pointing at a non-existent stub binary. The adapter
  # bubbles up bash's canonical 127 "command not found" exit — assert that
  # explicitly via `run -127` (silences bats BW01) so a future refactor that
  # maps missing-binary to a typed exit code (e.g. EXIT_TOOL_MISSING) fails
  # this test loudly and forces the contract to be re-declared here.
  PLAYWRIGHT_CLI_BIN="/nonexistent/playwright-cli-binary" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run -127 bash "${SCRIPTS_DIR}/browser-snapshot.sh" --capture
  [ -f "${BROWSER_SKILL_HOME}/captures/001/meta.json" ] || fail "meta.json not finalized after error"
  jq -e '.status == "error"' "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
}

# ---------- Phase 14 (Bundle #1): heavy snapshots → file ref (spec §3.2) ----------

# Stub binary that prints ~3 KB of YAML — simulates a real-world snapshot.
fat_snapshot_stub() {
  local stub
  stub="$(mktemp "${TMPDIR:-/tmp}/playwright-fat.XXXXXX")"
  cat > "${stub}" <<'EOF'
#!/usr/bin/env bash
{
  printf '### Page\n- Page URL: http://localhost:8090/test\n- Page Title: Big Page\n'
  printf '### Snapshot\n```yaml\n'
  for i in $(seq 1 60); do
    printf -- '- generic [ref=e%d]: lorem ipsum dolor sit amet consectetur adipiscing elit\n' "${i}"
  done
  printf '```\n'
}
EOF
  chmod +x "${stub}"
  printf '%s\n' "${stub}"
}

@test "browser-snapshot: large output (> threshold) writes snapshot_path + n_refs in summary" {
  local stub
  stub="$(fat_snapshot_stub)"
  run env BROWSER_SKILL_SNAPSHOT_INLINE_BYTES=1024 \
        PLAYWRIGHT_CLI_BIN="${stub}" \
    bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  local rc="${status}"
  rm -f "${stub}"
  [ "${rc}" -eq 0 ] || fail "expected status 0, got ${rc} — output: ${output}"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.snapshot_path | type == "string"' >/dev/null \
    || fail "missing snapshot_path: ${last_line}"
  printf '%s' "${last_line}" | jq -e '.n_refs >= 60' >/dev/null \
    || fail "n_refs not counted: ${last_line}"
  local path
  path="$(printf '%s' "${last_line}" | jq -r '.snapshot_path')"
  [ -f "${path}" ] || fail "snapshot_path file not written: ${path}"
  local file_size
  file_size="$(wc -c < "${path}" | tr -d ' ')"
  [ "${file_size}" -gt 1024 ] || fail "file too small (${file_size}B); expected > 1024"
}

@test "browser-snapshot: small output (<= threshold) stays inline (no snapshot_path key)" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e 'has("snapshot_path") | not' >/dev/null \
    || fail "small output should NOT have snapshot_path: ${last_line}"
}

@test "browser-snapshot: large output truncates stdout body to <= teaser cap" {
  local stub teaser_cap=512
  stub="$(fat_snapshot_stub)"
  run env BROWSER_SKILL_SNAPSHOT_INLINE_BYTES=1024 \
        BROWSER_SKILL_SNAPSHOT_TEASER_BYTES="${teaser_cap}" \
        PLAYWRIGHT_CLI_BIN="${stub}" \
    bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  local rc="${status}"
  rm -f "${stub}"
  [ "${rc}" -eq 0 ] || fail "status ${rc} — ${output}"
  # Reconstruct non-summary stdout body byte count (everything before the last JSON line).
  local body_bytes=0 i
  local nlines="${#lines[@]}"
  for (( i = 0; i < nlines - 1; i++ )); do
    body_bytes=$(( body_bytes + ${#lines[i]} + 1 ))
  done
  # teaser_cap + footer (~120B for "... full snapshot at <path>; N refs)").
  local upper_bound=$(( teaser_cap + 256 ))
  [ "${body_bytes}" -le "${upper_bound}" ] \
    || fail "expected stdout body <= ${upper_bound}B, got ${body_bytes}B"
}

@test "browser-snapshot: large-output file mode is 0600 (per spec §6)" {
  local stub
  stub="$(fat_snapshot_stub)"
  run env BROWSER_SKILL_SNAPSHOT_INLINE_BYTES=1024 \
        PLAYWRIGHT_CLI_BIN="${stub}" \
    bash "${SCRIPTS_DIR}/browser-snapshot.sh"
  local rc="${status}"
  rm -f "${stub}"
  [ "${rc}" -eq 0 ] || fail "status ${rc}"
  local last_line path perms
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  path="$(printf '%s' "${last_line}" | jq -r '.snapshot_path')"
  perms="$(stat -c '%a' "${path}" 2>/dev/null || stat -f '%Lp' "${path}" 2>/dev/null)"
  [ "${perms}" = "600" ] || fail "expected file mode 600, got ${perms}"
}
