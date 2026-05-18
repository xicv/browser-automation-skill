load helpers

# Phase 13: tests for the weak-fingerprint selector rescue.
# Covers: CSS selector → fingerprint parsing, rescue helper plumbing,
# memory_record_heal updates archetype + self_heal_history.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  unset BROWSER_DO_RESCUE_THRESHOLD
}
teardown() {
  teardown_temp_home
}

# --- selector parser -----------------------------------------------------

@test "_memory_parse_selector_to_fp: 'button.delete' → tag=BUTTON + class=delete" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/memory.sh"
  init_paths
  result="$(_memory_parse_selector_to_fp 'button.delete')"
  printf '%s' "${result}" | jq -e '
    .tag == "BUTTON" and (.classes | index("delete")) != null
  ' >/dev/null
}

@test "_memory_parse_selector_to_fp: 'button.btn.delete' → both classes captured" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/memory.sh"
  init_paths
  result="$(_memory_parse_selector_to_fp 'button.btn.delete')"
  printf '%s' "${result}" | jq -e '
    .tag == "BUTTON"
    and (.classes | index("btn"))    != null
    and (.classes | index("delete")) != null
  ' >/dev/null
}

@test "_memory_parse_selector_to_fp: '#submit' → tag=* + attrs.id=submit" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/memory.sh"
  init_paths
  result="$(_memory_parse_selector_to_fp '#submit')"
  printf '%s' "${result}" | jq -e '
    .tag == "*" and .attrs.id == "submit"
  ' >/dev/null
}

@test "_memory_parse_selector_to_fp: empty selector → tag=* + empty classes" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/memory.sh"
  init_paths
  result="$(_memory_parse_selector_to_fp '')"
  printf '%s' "${result}" | jq -e '
    .tag == "*" and (.classes | length) == 0
  ' >/dev/null
}

@test "_memory_parse_selector_to_fp: unknown combinators (>, +, ~) degrade gracefully" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/memory.sh"
  init_paths
  result="$(_memory_parse_selector_to_fp 'form > button.submit')"
  # Picks up the first tag + class even with combinator noise — weak fingerprint
  # is the documented contract.
  printf '%s' "${result}" | jq -e '
    .tag == "FORM" and (.classes | index("submit")) != null
  ' >/dev/null
}

# --- memory_record_heal -------------------------------------------------

@test "memory_record_heal: overwrites selector, resets fail_count, appends self_heal_history" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/memory.sh"
  init_paths

  # Seed an archetype with one interaction that has accumulated fails.
  memory_init_dir
  mkdir -p "${BROWSER_SKILL_HOME}/memory/myapp/archetypes"
  chmod 700 "${BROWSER_SKILL_HOME}/memory/myapp" "${BROWSER_SKILL_HOME}/memory/myapp/archetypes"
  arch_path="${BROWSER_SKILL_HOME}/memory/myapp/archetypes/devices-id.json"
  jq -nc '{
    schema_version:1,
    url_pattern:"/devices/:id",
    use_count:5, last_seen:"2026-05-18T00:00:00Z",
    interactions:[{
      intent:"click delete", selector:"button.delete",
      first_used:"2026-05-15T00:00:00Z", last_used:"2026-05-17T00:00:00Z",
      success_count:3, fail_count:2, disabled:false, self_heal_history:[]
    }]
  }' > "${arch_path}"
  chmod 600 "${arch_path}"

  memory_record_heal myapp devices-id "click delete" \
                     "button.delete" "button[data-testid=delete-btn]"

  # selector updated; fail_count reset; success_count bumped; history grew.
  jq -e '
    (.interactions[0].selector == "button[data-testid=delete-btn]")
    and (.interactions[0].fail_count == 0)
    and (.interactions[0].success_count == 4)
    and (.interactions[0].disabled == false)
    and ((.interactions[0].self_heal_history | length) == 1)
    and (.interactions[0].self_heal_history[0].event == "rescued")
    and (.interactions[0].self_heal_history[0].from_selector == "button.delete")
    and (.interactions[0].self_heal_history[0].to_selector   == "button[data-testid=delete-btn]")
  ' "${arch_path}" >/dev/null
}

@test "memory_record_heal: refuses on missing archetype" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/memory.sh"
  init_paths
  memory_init_dir
  run memory_record_heal myapp nonexistent-arch "irrelevant" "a" "b"
  [ "${status}" -eq "${EXIT_USAGE_ERROR}" ]
}

# --- memory_fingerprint_rescue (no live browser; just verify pipeline + fallback) ---

@test "memory_fingerprint_rescue: missing fingerprint JS file → empty rescue (best-effort)" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/memory.sh"
  init_paths
  # Hide the JS template; helper should warn + return empty.
  local js="${LIB_DIR}/fingerprint-rescue.js"
  local bak="${js}.bak.$$"
  [ -f "${js}" ] || skip "fingerprint-rescue.js not present"
  mv "${js}" "${bak}"
  rescued="$(memory_fingerprint_rescue myapp devices-id "click delete" "button.delete" 2>/dev/null)"
  mv "${bak}" "${js}"
  [ -z "${rescued}" ]
}

@test "memory_fingerprint_rescue: empty cached selector → empty (no parse, no eval)" {
  source "${LIB_DIR}/common.sh"
  source "${LIB_DIR}/memory.sh"
  init_paths
  rescued="$(memory_fingerprint_rescue myapp devices-id "click delete" "" 2>/dev/null)"
  [ -z "${rescued}" ]
}
