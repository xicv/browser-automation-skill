load helpers

# Phase 9 part 1-v — baseline save/list/remove (closes Phase 9 alongside
# history.bats). Thin wrapper over Phase 7's meta.is_baseline:true.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

_seed_one_capture() {
  BROWSER_SKILL_LIB_STUB=1 \
    bash "${SCRIPTS_DIR}/browser-flow.sh" run "${FIXTURES_DIR}/flows/simple.flow.yaml" >/dev/null 2>&1
}

# --- baseline save ---

@test "baseline save: writes baselines.json mode 0600 + sets is_baseline:true on meta.json" {
  _seed_one_capture
  run bash "${SCRIPTS_DIR}/browser-baseline.sh" save 001 --as after-redesign
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/baselines.json" ] || fail "baselines.json missing"
  mode="$(stat -c '%a' "${BROWSER_SKILL_HOME}/baselines.json" 2>/dev/null || stat -f '%Lp' "${BROWSER_SKILL_HOME}/baselines.json" 2>/dev/null)"
  [ "${mode}" = "600" ] || fail "expected mode 600 on baselines.json; got ${mode}"
  jq -e '.is_baseline == true' "${BROWSER_SKILL_HOME}/captures/001/meta.json" >/dev/null
  jq -e '.baselines | length == 1 and .[0].name == "after-redesign" and .[0].capture_id == "001"' \
    "${BROWSER_SKILL_HOME}/baselines.json" >/dev/null
}

@test "baseline save: missing --as fails EXIT_USAGE_ERROR" {
  _seed_one_capture
  run bash "${SCRIPTS_DIR}/browser-baseline.sh" save 001
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--as"
}

@test "baseline save: nonexistent capture-id fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-baseline.sh" save 999 --as ghost
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such capture"
}

# --- baseline list ---

@test "baseline list: empty → exit 0; zero rows" {
  run bash "${SCRIPTS_DIR}/browser-baseline.sh" list
  assert_status 0
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "baseline" and .total == 0' >/dev/null
}

@test "baseline list: 2 baselines → 2 rows + total:2 in summary" {
  _seed_one_capture
  _seed_one_capture
  bash "${SCRIPTS_DIR}/browser-baseline.sh" save 001 --as first >/dev/null
  bash "${SCRIPTS_DIR}/browser-baseline.sh" save 002 --as second >/dev/null
  run bash "${SCRIPTS_DIR}/browser-baseline.sh" list
  assert_status 0
  rows="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(.event=="baseline_row")) | length')"
  [ "${rows}" = "2" ] || fail "expected 2 baseline_row events; got ${rows}"
}

# --- baseline remove ---

@test "baseline remove: clears is_baseline + splices baselines.json; capture dir UNTOUCHED" {
  _seed_one_capture
  bash "${SCRIPTS_DIR}/browser-baseline.sh" save 001 --as to-remove >/dev/null
  run bash "${SCRIPTS_DIR}/browser-baseline.sh" remove to-remove
  assert_status 0
  # is_baseline cleared from meta.json (false or absent).
  is_baseline="$(jq -r '.is_baseline // false' "${BROWSER_SKILL_HOME}/captures/001/meta.json")"
  [ "${is_baseline}" = "false" ] || fail "expected is_baseline:false after remove; got ${is_baseline}"
  # baselines.json no longer carries the entry.
  count="$(jq '.baselines | length' "${BROWSER_SKILL_HOME}/baselines.json")"
  [ "${count}" = "0" ] || fail "expected 0 baselines after remove; got ${count}"
  # Capture dir still exists.
  [ -d "${BROWSER_SKILL_HOME}/captures/001" ] || fail "capture dir should NOT be deleted by baseline remove"
}
