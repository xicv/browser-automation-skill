load helpers

# Phase 11 part 1-i — lib/memory.sh foundation.
# Pure lib tests; no verb integration. URL→archetype resolution via Node 20+
# URLPattern web standard (scripts/lib/node/url-pattern-resolver.mjs).

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  # shellcheck disable=SC1091
  source "${LIB_DIR}/memory.sh"
}
teardown() { teardown_temp_home; }

# Compact archetype JSON helper — keeps test bodies readable.
_arch_json() {
  local id="$1" pattern="$2"
  jq -nc --arg id "${id}" --arg p "${pattern}" \
    '{schema_version:1, archetype_id:$id, url_pattern:$p,
      first_seen:"2026-05-10T00:00:00Z", last_seen:"2026-05-10T00:00:00Z",
      use_count:0, interactions:[]}'
}

# --- memory_init_dir ---

@test "memory_init_dir: creates memory/ mode 0700; idempotent" {
  memory_init_dir
  [ -d "${BROWSER_SKILL_HOME}/memory" ] || fail "memory/ not created"
  mode="$(file_mode "${BROWSER_SKILL_HOME}/memory")"
  [ "${mode}" = "700" ] || fail "expected mode 700; got ${mode}"

  # Second call must not fail and must not change perms.
  memory_init_dir
  mode2="$(file_mode "${BROWSER_SKILL_HOME}/memory")"
  [ "${mode2}" = "700" ] || fail "mode changed on idempotent re-call: ${mode2}"
}

# --- memory_save_archetype + memory_load_archetype ---

@test "memory_save + memory_load: round-trip; archetype file mode 0600; per-site dir mode 0700" {
  json="$(_arch_json devices-detail '/devices/:id')"
  memory_save_archetype prod-app devices-detail "${json}"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  [ -f "${arch_path}" ] || fail "archetype file not written"
  mode="$(file_mode "${arch_path}")"
  [ "${mode}" = "600" ] || fail "expected archetype file mode 600; got ${mode}"

  site_dir="${BROWSER_SKILL_HOME}/memory/prod-app"
  site_mode="$(file_mode "${site_dir}")"
  [ "${site_mode}" = "700" ] || fail "expected per-site dir mode 700; got ${site_mode}"

  loaded="$(memory_load_archetype prod-app devices-detail)"
  # Equality on canonical jq output (handles whitespace differences).
  [ "$(printf '%s' "${loaded}" | jq -cS .)" = "$(printf '%s' "${json}" | jq -cS .)" ] \
    || fail "round-trip mismatch: in=${json} out=${loaded}"
}

# --- memory_lookup ---

@test "memory_lookup: returns selector for matching (site, archetype, intent)" {
  base="$(_arch_json devices-detail '/devices/:id')"
  json="$(printf '%s' "${base}" | jq -c '.interactions = [
    {intent:"click delete button", selector:"button[data-testid=delete]",
     first_used:"2026-05-10T00:00:00Z", last_used:"2026-05-10T00:00:00Z",
     success_count:1, fail_count:0, disabled:false, self_heal_history:[]}]')"
  memory_save_archetype prod-app devices-detail "${json}"

  sel="$(memory_lookup prod-app devices-detail "click delete button")"
  [ "${sel}" = "button[data-testid=delete]" ] || fail "expected selector; got '${sel}'"
}

@test "memory_lookup: empty string on cache miss" {
  json="$(_arch_json devices-detail '/devices/:id')"
  memory_save_archetype prod-app devices-detail "${json}"

  sel="$(memory_lookup prod-app devices-detail "no such intent")"
  [ -z "${sel}" ] || fail "expected empty on miss; got '${sel}'"
}

@test "memory_lookup: empty string when archetype file missing" {
  sel="$(memory_lookup prod-app ghost-archetype "anything")"
  [ -z "${sel}" ] || fail "expected empty when archetype absent; got '${sel}'"
}

# --- memory_record ---

@test "memory_record: new interaction sets first_used + last_used + success_count:1 + disabled:false" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click delete" "button.delete"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '
    .interactions | length == 1 and
    .[0].intent == "click delete" and
    .[0].selector == "button.delete" and
    .[0].success_count == 1 and
    .[0].fail_count == 0 and
    .[0].disabled == false and
    (.[0].first_used | length > 0) and
    (.[0].last_used | length > 0)
  ' "${arch_path}" >/dev/null || fail "interaction shape wrong: $(cat "${arch_path}")"
}

@test "memory_record: existing intent → success_count++; first_used preserved; last_used advances" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click save" "button.save"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  first_seen="$(jq -r '.interactions[0].first_used' "${arch_path}")"
  sleep 1   # bump timestamp; now_iso is second-precision.

  memory_record prod-app devices-detail "click save" "button.save"
  jq -e '.interactions | length == 1 and .[0].success_count == 2' "${arch_path}" >/dev/null \
    || fail "expected success_count:2 + length:1; got $(jq -c '.interactions' "${arch_path}")"
  preserved="$(jq -r '.interactions[0].first_used' "${arch_path}")"
  [ "${preserved}" = "${first_seen}" ] || fail "first_used clobbered: was=${first_seen} now=${preserved}"
}

# --- memory_record_failure ---

@test "memory_record_failure: increments fail_count under threshold; disabled stays false" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click save" "button.save"
  memory_record_failure prod-app devices-detail "click save"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '.interactions[0].fail_count == 1 and .interactions[0].disabled == false' \
    "${arch_path}" >/dev/null || fail "expected fail_count:1 + disabled:false"
}

@test "memory_record_failure: 4th failure (fail_count > 3) sets disabled:true" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click save" "button.save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '.interactions[0].fail_count == 4 and .interactions[0].disabled == true' \
    "${arch_path}" >/dev/null || fail "expected disabled:true at fail_count:4"
}

# --- memory_record_pattern ---

@test "memory_record_pattern: writes patterns.json mode 0600; idempotent on same (pattern, archetype)" {
  memory_record_pattern prod-app '/devices/:id' devices-detail
  patterns_path="${BROWSER_SKILL_HOME}/memory/prod-app/patterns.json"
  [ -f "${patterns_path}" ] || fail "patterns.json not written"
  mode="$(file_mode "${patterns_path}")"
  [ "${mode}" = "600" ] || fail "expected patterns.json mode 600; got ${mode}"
  jq -e '.patterns | length == 1 and .[0].url_pattern == "/devices/:id" and .[0].archetype_id == "devices-detail"' \
    "${patterns_path}" >/dev/null || fail "shape wrong: $(cat "${patterns_path}")"

  # Idempotent: re-recording same pair → still length 1.
  memory_record_pattern prod-app '/devices/:id' devices-detail
  count="$(jq '.patterns | length' "${patterns_path}")"
  [ "${count}" = "1" ] || fail "expected length 1 after re-record; got ${count}"
}

# --- memory_resolve_archetype ---

@test "memory_resolve_archetype: /devices/:id matches /devices/123 → echoes devices-detail" {
  memory_record_pattern prod-app '/devices/:id' devices-detail
  arch="$(memory_resolve_archetype prod-app 'https://prod.example.com/devices/123')"
  [ "${arch}" = "devices-detail" ] || fail "expected devices-detail; got '${arch}'"
}

@test "memory_resolve_archetype: non-matching URL → empty" {
  memory_record_pattern prod-app '/devices/:id' devices-detail
  arch="$(memory_resolve_archetype prod-app 'https://prod.example.com/users/profile')"
  [ -z "${arch}" ] || fail "expected empty on miss; got '${arch}'"
}
