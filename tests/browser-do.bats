load helpers

# Phase 11 part 1-ii — browser-do verb (cache lookup + dispatch + write-back).
# Stub-click via existing playwright-cli stub: browser-do → browser-click.sh → stub.

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  # shellcheck disable=SC1091
  source "${LIB_DIR}/memory.sh"
}
teardown() { teardown_temp_home; }

# Helper: seed cache so subsequent --intent calls hit.
_seed_cache() {
  local site="$1" arch="$2" pattern="$3" intent="$4" selector="$5"
  local arch_json
  arch_json="$(jq -nc --arg id "${arch}" --arg p "${pattern}" \
    '{schema_version:1, archetype_id:$id, url_pattern:$p,
      first_seen:"2026-05-10T00:00:00Z", last_seen:"2026-05-10T00:00:00Z",
      use_count:0, interactions:[]}')"
  memory_save_archetype "${site}" "${arch}" "${arch_json}"
  memory_record "${site}" "${arch}" "${intent}" "${selector}"
  memory_record_pattern "${site}" "${pattern}" "${arch}"
}

# Helper: register a site so dispatched verbs (browser-click) can resolve it
# if they need site-context. Most tests use --site override; this is just so
# the dispatched verb doesn't trip a "site not found" check.
_register_site() {
  local name="$1"
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name "${name}" --url 'https://stub.example.com' >/dev/null
}

# --- --intent: cache hit dispatch ---

@test "browser-do --intent: cache hit → dispatches click stub + exit 0 + cache_hit:true" {
  _register_site app
  _seed_cache app devices-id '/devices/:id' "click delete" "button.delete"
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-do.sh" \
      --site app --verb click \
      --intent "click delete" \
      --url 'https://app.example.com/devices/123'
  assert_status 0
  # Stub recorded the dispatched click.
  grep -q '^click$' "${STUB_LOG_FILE}" || fail "stub did not record click; log: $(cat "${STUB_LOG_FILE}")"
  # Final summary line carries cache_hit:true.
  last="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last}" | jq -e '.verb == "do" and .mode == "intent" and .cache_hit == true' >/dev/null \
    || fail "summary line wrong: ${last}"
  rm -f "${STUB_LOG_FILE}"
}

# --- --intent: cache miss (no archetype for URL) ---

@test "browser-do --intent: no archetype matches URL → exit 11 + reason:no_pattern_for_url" {
  _register_site app
  run bash "${SCRIPTS_DIR}/browser-do.sh" \
    --site app --verb click \
    --intent "click delete" \
    --url 'https://app.example.com/devices/123'
  assert_status 11
  found="$(printf '%s\n' "${lines[@]}" | jq -s 'map(select(._kind=="cache_miss")) | length')"
  [ "${found}" = "1" ] || fail "expected exactly one cache_miss event; output: ${output}"
  reason="$(printf '%s\n' "${lines[@]}" | jq -rs 'map(select(._kind=="cache_miss"))[0].reason')"
  [ "${reason}" = "no_pattern_for_url" ] || fail "expected reason:no_pattern_for_url; got ${reason}"
}

# --- --intent: cache miss (intent not cached) ---

@test "browser-do --intent: intent unknown but archetype known → exit 11 + reason:intent_not_cached" {
  _register_site app
  _seed_cache app devices-id '/devices/:id' "click save" "button.save"
  run bash "${SCRIPTS_DIR}/browser-do.sh" \
    --site app --verb click \
    --intent "click delete-that-was-never-cached" \
    --url 'https://app.example.com/devices/123'
  assert_status 11
  reason="$(printf '%s\n' "${lines[@]}" | jq -rs 'map(select(._kind=="cache_miss"))[0].reason')"
  [ "${reason}" = "intent_not_cached" ] || fail "expected reason:intent_not_cached; got ${reason}"
}

# --- --intent: invalid --verb (whitelist enforcement) ---

@test "browser-do --intent: --verb ghost rejected (whitelist) → exit 2" {
  _register_site app
  run bash "${SCRIPTS_DIR}/browser-do.sh" \
    --site app --verb ghost \
    --intent "anything" \
    --url 'https://app.example.com/x'
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "verb"
}

# --- --intent: missing --site AND no current ---

@test "browser-do --intent: no --site and no current → exit 2" {
  run bash "${SCRIPTS_DIR}/browser-do.sh" \
    --verb click --intent "anything" \
    --url 'https://app.example.com/x'
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "site"
}

# --- --intent: --site overrides current ---

@test "browser-do --intent: --site overrides current_get" {
  _register_site app
  _register_site other
  bash "${SCRIPTS_DIR}/browser-use.sh" --set other >/dev/null
  # Reuse the same selector + URL as test 1 so the playwright-cli fixture
  # for ['click','button.delete'] matches.
  _seed_cache app devices-id '/devices/:id' "click delete" "button.delete"
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-do.sh" \
      --site app --verb click \
      --intent "click delete" \
      --url 'https://app.example.com/devices/123'
  assert_status 0
  rm -f "${STUB_LOG_FILE}"
}

# --- record: writes interaction + pattern; mode 0600 ---

@test "browser-do record: writes archetype + patterns.json mode 0600" {
  run bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app \
    --intent "click save" \
    --selector "button.save" \
    --url 'https://app.example.com/devices/42'
  assert_status 0
  arch_path="${BROWSER_SKILL_HOME}/memory/app/archetypes/devices-id.json"
  patterns_path="${BROWSER_SKILL_HOME}/memory/app/patterns.json"
  [ -f "${arch_path}" ] || fail "archetype not written"
  [ -f "${patterns_path}" ] || fail "patterns.json not written"
  am="$(file_mode "${arch_path}")"; pm="$(file_mode "${patterns_path}")"
  [ "${am}" = "600" ] && [ "${pm}" = "600" ] || fail "expected mode 600; got arch=${am} patterns=${pm}"
  jq -e '.interactions | length == 1 and .[0].intent == "click save" and .[0].selector == "button.save"' \
    "${arch_path}" >/dev/null || fail "shape wrong: $(cat "${arch_path}")"
}

# --- record: --pattern auto-derived from URL ---

@test "browser-do record: auto-derives /devices/:id pattern from /devices/123 URL" {
  bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app --intent "click save" --selector "button.save" \
    --url 'https://app.example.com/devices/123' >/dev/null
  jq -e '.patterns[0].url_pattern == "/devices/:id"' \
    "${BROWSER_SKILL_HOME}/memory/app/patterns.json" >/dev/null \
    || fail "expected /devices/:id; got $(jq -r '.patterns[0].url_pattern' "${BROWSER_SKILL_HOME}/memory/app/patterns.json")"
}

# --- record: --pattern overrides auto-derivation ---

@test "browser-do record: --pattern overrides auto-derivation" {
  bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app --intent "click save" --selector "button.save" \
    --url 'https://app.example.com/devices/123' \
    --pattern '/devices/:deviceId' >/dev/null
  jq -e '.patterns[0].url_pattern == "/devices/:deviceId"' \
    "${BROWSER_SKILL_HOME}/memory/app/patterns.json" >/dev/null
}

# --- record: --archetype overrides auto-derivation ---

@test "browser-do record: --archetype overrides auto-derivation" {
  bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app --intent "click save" --selector "button.save" \
    --url 'https://app.example.com/devices/123' \
    --archetype custom-name >/dev/null
  [ -f "${BROWSER_SKILL_HOME}/memory/app/archetypes/custom-name.json" ] \
    || fail "expected custom-named archetype file"
}

# --- record: privacy canary in intent ---

@test "browser-do record: PASSWORD-CANARY in --intent → exit 28; cache untouched" {
  run bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app \
    --intent "type PASSWORD-CANARY now" \
    --selector "input" \
    --url 'https://app.example.com/login'
  assert_status "$EXIT_BLOCKLIST_REJECTED"
  [ ! -d "${BROWSER_SKILL_HOME}/memory/app" ] || fail "memory dir written despite canary refusal"
}

# --- record: privacy canary in selector ---

@test "browser-do record: PASSWORD-CANARY in --selector → exit 28; cache untouched" {
  run bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app \
    --intent "click button" \
    --selector "input[name=PASSWORD-CANARY]" \
    --url 'https://app.example.com/x'
  assert_status "$EXIT_BLOCKLIST_REJECTED"
  [ ! -d "${BROWSER_SKILL_HOME}/memory/app" ] || fail "memory dir written despite canary refusal"
}

# --- record: missing required flags ---

@test "browser-do record: missing --intent → exit 2" {
  run bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app --selector "x" --url 'https://x/y'
  assert_status "$EXIT_USAGE_ERROR"
}

@test "browser-do record: missing --selector → exit 2" {
  run bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app --intent "x" --url 'https://x/y'
  assert_status "$EXIT_USAGE_ERROR"
}

@test "browser-do record: missing --url → exit 2" {
  run bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app --intent "x" --selector "y"
  assert_status "$EXIT_USAGE_ERROR"
}

# --- 1-iii self-heal: post-dispatch failure trigger ---
#
# Tests use BROWSER_DO_DISPATCH_OVERRIDE — a test-only env hook (documented in
# scripts/browser-do.sh) that lets us mock the dispatched verb's exit code.
# The wrapper script ignores its argv and exits with $MOCK_DISPATCH_EXIT.

_make_mock_dispatcher() {
  local exit_code="$1"
  local script_path="${BATS_TEST_TMPDIR:-/tmp}/mock-dispatch-${BATS_TEST_NUMBER:-x}.sh"
  cat > "${script_path}" <<EOF
#!/usr/bin/env bash
# Mock dispatcher for browser-do self-heal tests. Exit code controlled by env.
# Args ignored.
exit ${exit_code}
EOF
  chmod +x "${script_path}"
  printf '%s' "${script_path}"
}

@test "browser-do --intent (self-heal): dispatched verb exits 11 → memory_record_failure invoked → fail_count == 1" {
  _register_site app
  _seed_cache app devices-id '/devices/:id' "click thing" "button.thing"
  arch_path="${BROWSER_SKILL_HOME}/memory/app/archetypes/devices-id.json"
  jq -e '.interactions[0].fail_count == 0' "${arch_path}" >/dev/null

  override="$(_make_mock_dispatcher 11)"
  BROWSER_DO_DISPATCH_OVERRIDE="${override}" \
    run bash "${SCRIPTS_DIR}/browser-do.sh" \
      --site app --verb click \
      --intent "click thing" \
      --url 'https://app.example.com/devices/123'
  # browser-do forwards dispatcher's exit (11). action correctness over cache freshness.
  assert_status 11
  jq -e '.interactions[0].fail_count == 1 and .interactions[0].disabled == false' \
    "${arch_path}" >/dev/null || fail "expected fail_count:1 + disabled:false; got $(jq -c '.interactions[0]' "${arch_path}")"
}

@test "browser-do --intent (self-heal): dispatched verb exits 13 → memory_record_failure invoked" {
  _register_site app
  _seed_cache app devices-id '/devices/:id' "click thing" "button.thing"
  arch_path="${BROWSER_SKILL_HOME}/memory/app/archetypes/devices-id.json"

  override="$(_make_mock_dispatcher 13)"
  BROWSER_DO_DISPATCH_OVERRIDE="${override}" \
    run bash "${SCRIPTS_DIR}/browser-do.sh" \
      --site app --verb click \
      --intent "click thing" \
      --url 'https://app.example.com/devices/123'
  assert_status 13
  jq -e '.interactions[0].fail_count == 1' "${arch_path}" >/dev/null
}

@test "browser-do --intent (self-heal): dispatched verb exits 30 (network) → fail_count NOT incremented" {
  _register_site app
  _seed_cache app devices-id '/devices/:id' "click thing" "button.thing"
  arch_path="${BROWSER_SKILL_HOME}/memory/app/archetypes/devices-id.json"

  override="$(_make_mock_dispatcher 30)"
  BROWSER_DO_DISPATCH_OVERRIDE="${override}" \
    run bash "${SCRIPTS_DIR}/browser-do.sh" \
      --site app --verb click \
      --intent "click thing" \
      --url 'https://app.example.com/devices/123'
  assert_status 30
  jq -e '.interactions[0].fail_count == 0' "${arch_path}" >/dev/null \
    || fail "fail_count incremented despite environmental error; got $(jq -c '.interactions[0]' "${arch_path}")"
}

@test "browser-do --intent + record (self-heal end-to-end): 4 failures disable; record heals" {
  _register_site app
  _seed_cache app devices-id '/devices/:id' "click thing" "button.OLD"
  arch_path="${BROWSER_SKILL_HOME}/memory/app/archetypes/devices-id.json"

  override="$(_make_mock_dispatcher 11)"
  for _ in 1 2 3 4; do
    BROWSER_DO_DISPATCH_OVERRIDE="${override}" \
      bash "${SCRIPTS_DIR}/browser-do.sh" \
        --site app --verb click --intent "click thing" \
        --url 'https://app.example.com/devices/123' >/dev/null 2>&1 || true
  done
  jq -e '.interactions[0].disabled == true and .interactions[0].fail_count == 4' \
    "${arch_path}" >/dev/null || fail "expected disabled:true after 4 failures; got $(jq -c '.interactions[0]' "${arch_path}")"

  # Next --intent: lookup transparently skips disabled → cache_miss (intent_not_cached).
  run bash "${SCRIPTS_DIR}/browser-do.sh" \
    --site app --verb click --intent "click thing" \
    --url 'https://app.example.com/devices/123'
  assert_status 11
  reason="$(printf '%s\n' "${lines[@]}" | jq -rs 'map(select(._kind=="cache_miss"))[0].reason')"
  [ "${reason}" = "intent_not_cached" ] || fail "expected reason:intent_not_cached after disable; got ${reason}"

  # Agent re-resolves + records: overwrites disabled entry with fresh selector.
  bash "${SCRIPTS_DIR}/browser-do.sh" record \
    --site app --intent "click thing" --selector "button.NEW" \
    --url 'https://app.example.com/devices/123' >/dev/null
  jq -e '
    .interactions | length == 1 and
    .[0].selector == "button.NEW" and
    .[0].disabled == false and
    .[0].fail_count == 0
  ' "${arch_path}" >/dev/null || fail "expected healed shape after record; got $(jq -c '.interactions[0]' "${arch_path}")"
}
