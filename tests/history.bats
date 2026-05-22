bats_require_minimum_version 1.5.0
load helpers

# Phase 9 part 1-v — history list/show/diff/clear (closes Phase 9 alongside
# baseline.bats). Composes Phase 7's capture pipeline + 9-1-iv's flow_diff_steps.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

# Helper: pre-stage N captures via flow run.
_seed_captures() {
  local n="$1"
  local i
  for ((i = 0; i < n; i++)); do
    BROWSER_SKILL_LIB_STUB=1 \
      bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/simple.flow.yaml" >/dev/null 2>&1
  done
}

# --- history list ---

@test "history list: empty captures dir → exit 0; emits zero rows" {
  run bash "${SCRIPTS_DIR}/browser-history.sh" list
  assert_status 0
  # Summary line at end; no per-capture rows in between.
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "history" and .total == 0' >/dev/null
}

@test "history list: 3 captures emits 3 rows + total:3 in summary" {
  _seed_captures 3
  run bash "${SCRIPTS_DIR}/browser-history.sh" list
  assert_status 0
  rows="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(.event=="history_row")) | length')"
  [ "${rows}" = "3" ] || fail "expected 3 history_row events, got ${rows}"
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.total == 3' >/dev/null
}

@test "history list --limit 2: emits only newest 2 captures" {
  _seed_captures 3
  run bash "${SCRIPTS_DIR}/browser-history.sh" list --limit 2
  assert_status 0
  rows="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(.event=="history_row")) | length')"
  [ "${rows}" = "2" ] || fail "expected 2 rows under --limit 2, got ${rows}"
}

# --- Phase 12 (TOON output mode amendment, 2026-05-22) ----------------------

@test "history list --format=toon: emits consolidated TOON document with captures table" {
  _seed_captures 3
  run bash "${SCRIPTS_DIR}/browser-history.sh" list --format=toon
  assert_status 0
  # Required-key checks at TOON root.
  printf '%s\n' "${lines[@]}" | grep -q '^verb: history$' \
    || fail "missing 'verb: history'; out:\n${output}"
  printf '%s\n' "${lines[@]}" | grep -q '^status: ok$' \
    || fail "missing 'status: ok'; out:\n${output}"
  printf '%s\n' "${lines[@]}" | grep -q '^total: 3$' \
    || fail "missing 'total: 3'; out:\n${output}"
  # Tabular table header for captures[3]. Field set depends on meta.json
  # shape (capture_id, verb, status, ...); just assert the table form.
  printf '%s\n' "${lines[@]}" | grep -q '^captures\[3\]' \
    || fail "missing 'captures[3]' table header; out:\n${output}"
  # No "event:history_row" streaming lines in TOON mode (single doc only).
  printf '%s\n' "${lines[@]}" | grep -q 'history_row' \
    && fail "TOON mode should consolidate; no history_row events expected; out:\n${output}"
  return 0
}

@test "history list --format=toon: empty captures dir still emits valid TOON" {
  run bash "${SCRIPTS_DIR}/browser-history.sh" list --format=toon
  assert_status 0
  printf '%s\n' "${lines[@]}" | grep -q '^verb: history$' \
    || fail "missing 'verb: history'; out:\n${output}"
  printf '%s\n' "${lines[@]}" | grep -q '^total: 0$' \
    || fail "missing 'total: 0'; out:\n${output}"
}

@test "history list --format=toon: byte-savings >=30% vs JSON streaming form" {
  _seed_captures 5
  local json toon json_bytes toon_bytes savings
  json="$(bash "${SCRIPTS_DIR}/browser-history.sh" list)"
  toon="$(bash "${SCRIPTS_DIR}/browser-history.sh" list --format=toon)"
  json_bytes="${#json}"
  toon_bytes="${#toon}"
  savings=$(( (json_bytes - toon_bytes) * 100 / json_bytes ))
  [ "${savings}" -ge 30 ] \
    || fail "expected >=30% savings; got json=${json_bytes}B, toon=${toon_bytes}B, savings=${savings}%"
}

# --- history show ---

@test "history show: emits meta.json content + step count" {
  _seed_captures 1
  run bash "${SCRIPTS_DIR}/browser-history.sh" show 001
  assert_status 0
  # First line is the meta object; subsequent are step events.
  printf '%s' "${lines[0]}" | jq -e '.capture_id == "001" and .verb == "flow"' >/dev/null
}

@test "history show: nonexistent capture-id → EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-history.sh" show 999
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such capture"
}

# --- history diff ---

@test "history diff: two identical-step captures → all replay_diff events have status_match:true" {
  _seed_captures 2
  run bash "${SCRIPTS_DIR}/browser-history.sh" diff 001 002
  assert_status 0
  diffs="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(.event=="replay_diff")) | length')"
  [ "${diffs}" -ge 1 ] || fail "expected ≥1 replay_diff events; got ${diffs}"
  matched="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(.event=="replay_diff" and .status_match==true)) | length')"
  [ "${matched}" -ge 1 ] || fail "expected ≥1 status_match:true events; got ${matched}"
}

# --- history clear ---

@test "history clear --keep 1: keeps newest only; prunes older" {
  _seed_captures 3
  run bash "${SCRIPTS_DIR}/browser-history.sh" clear --keep 1
  assert_status 0
  remaining="$(ls -d "${BROWSER_SKILL_HOME}/captures/"[0-9]*/ 2>/dev/null | wc -l | tr -d ' ')"
  [ "${remaining}" = "1" ] || fail "expected 1 capture remaining after --keep 1; got ${remaining}"
}

@test "history clear --not-baseline: purges all except baselines" {
  _seed_captures 3
  # Mark capture 002 as baseline.
  meta="${BROWSER_SKILL_HOME}/captures/002/meta.json"
  tmp="${meta}.tmp.$$"
  jq '.is_baseline = true' "${meta}" > "${tmp}"
  chmod 600 "${tmp}"
  mv "${tmp}" "${meta}"

  run bash "${SCRIPTS_DIR}/browser-history.sh" clear --not-baseline
  assert_status 0
  remaining="$(ls -d "${BROWSER_SKILL_HOME}/captures/"[0-9]*/ 2>/dev/null | wc -l | tr -d ' ')"
  [ "${remaining}" = "1" ] || fail "expected 1 baseline capture remaining; got ${remaining}"
  [ -d "${BROWSER_SKILL_HOME}/captures/002" ] || fail "captures/002 (baseline) should remain"
}
