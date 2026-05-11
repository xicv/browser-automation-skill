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

# ---------- Pick A5: self_heal_history[] audit-trail population ----------
# Phase 11 1-iii shipped the disable mechanic (fail_count > 3 → disabled:true)
# + the D2 heal mechanic (memory_record resets fail_count + disabled). Both
# previously left self_heal_history[] empty — the field was reserved but no
# writer existed. Pick A5 lights up the audit trail: on the transition
# false→true (disable) and the transition true→false (heal), append a
# {ts, event, fail_count, selector_at_time} entry.

@test "self_heal_history: 4th failure appends one 'disabled' entry with fail_count:4 + selector_at_time" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click save" "button.save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '.interactions[0].self_heal_history | length == 1' "${arch_path}" >/dev/null \
    || fail "expected self_heal_history length 1; got $(jq -c '.interactions[0].self_heal_history' "${arch_path}")"
  jq -e '
    .interactions[0].self_heal_history[0] |
    .event == "disabled" and .fail_count == 4 and
    .selector_at_time == "button.save" and (.ts | length > 0)
  ' "${arch_path}" >/dev/null \
    || fail "disabled entry shape wrong: $(jq -c '.interactions[0].self_heal_history[0]' "${arch_path}")"
}

@test "self_heal_history: failures BELOW threshold (1-3) append NO entries" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click save" "button.save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '.interactions[0].fail_count == 3 and .interactions[0].disabled == false' \
    "${arch_path}" >/dev/null || fail "preconditions wrong"
  jq -e '.interactions[0].self_heal_history | length == 0' "${arch_path}" >/dev/null \
    || fail "expected 0 history entries while not-yet-disabled; got $(jq -c '.interactions[0].self_heal_history' "${arch_path}")"
}

@test "self_heal_history: failures BEYOND threshold (5th, 6th) do NOT double-log; only the transition fires" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click save" "button.save"
  # 4 failures → disabled (1 history entry expected).
  for _ in 1 2 3 4; do
    memory_record_failure prod-app devices-detail "click save"
  done
  # 5th + 6th failures: already disabled; lib spec is "log only on the
  # transition." Repeated calls must not append further entries.
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '.interactions[0].self_heal_history | length == 1' "${arch_path}" >/dev/null \
    || fail "transition is single-shot; got length $(jq '.interactions[0].self_heal_history | length' "${arch_path}")"
}

@test "self_heal_history: memory_record on a disabled interaction appends 'healed' entry; resets fail_count + disabled" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click save" "button.save"
  # Drive to disabled:true.
  for _ in 1 2 3 4; do
    memory_record_failure prod-app devices-detail "click save"
  done
  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '(.interactions[0].disabled == true) and (.interactions[0].self_heal_history | length == 1)' \
    "${arch_path}" >/dev/null || fail "precondition: disabled+1-entry not reached"

  # Now heal: agent re-records the same intent with a (possibly new) selector.
  memory_record prod-app devices-detail "click save" "button.save-v2"

  jq -e '.interactions[0].self_heal_history | length == 2' "${arch_path}" >/dev/null \
    || fail "expected 2 history entries after heal; got $(jq -c '.interactions[0].self_heal_history' "${arch_path}")"
  jq -e '
    .interactions[0].self_heal_history[1] |
    .event == "healed" and .selector_at_time == "button.save-v2" and (.ts | length > 0)
  ' "${arch_path}" >/dev/null \
    || fail "healed entry shape wrong: $(jq -c '.interactions[0].self_heal_history[1]' "${arch_path}")"
  # Heal also resets fail_count + disabled (Phase 11 1-iii D2 invariant unchanged).
  jq -e '.interactions[0].fail_count == 0 and .interactions[0].disabled == false' \
    "${arch_path}" >/dev/null || fail "heal did not reset fail_count + disabled"
}

@test "self_heal_history: memory_record on a NOT-disabled interaction does NOT append a 'healed' entry" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click save" "button.save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"
  # Not disabled yet (only 2 failures); a normal success path must not log
  # a heal event (nothing was broken).
  memory_record prod-app devices-detail "click save" "button.save"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '.interactions[0].self_heal_history | length == 0' "${arch_path}" >/dev/null \
    || fail "expected 0 history entries on non-healing success; got $(jq -c '.interactions[0].self_heal_history' "${arch_path}")"
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

# ---------- Pick A4: pattern-equivalence canonicalization ----------
# /devices/:id and /devices/:itemId describe the SAME URL family but differ
# in lexical name. memory_record_pattern's idempotency check used raw string
# equality, creating redundant rows. Locked decision: canonical key collapses
# all `:NAME` segments to `:_` for COMPARE only; original names preserved in
# storage. Idempotency drops the AND archetype_id clause — first-write wins
# on canonical match.

@test "memory_record_pattern: equivalent patterns (same archetype, different :NAME) collapse to 1 row" {
  memory_record_pattern prod-app '/devices/:id' devices-detail
  memory_record_pattern prod-app '/devices/:itemId' devices-detail

  patterns_path="${BROWSER_SKILL_HOME}/memory/prod-app/patterns.json"
  rows="$(jq '.patterns | length' "${patterns_path}")"
  [ "${rows}" = "1" ] || fail "expected 1 row after equivalent pattern; got ${rows}: $(cat "${patterns_path}")"
  jq -e '.patterns[0].hit_count == 2' "${patterns_path}" >/dev/null \
    || fail "expected hit_count:2 after equivalent re-record; got $(jq -c '.patterns[0]' "${patterns_path}")"
}

@test "memory_record_pattern: equivalent patterns preserve FIRST-WRITTEN url_pattern in storage" {
  memory_record_pattern prod-app '/devices/:id' devices-detail
  memory_record_pattern prod-app '/devices/:itemId' devices-detail

  patterns_path="${BROWSER_SKILL_HOME}/memory/prod-app/patterns.json"
  stored="$(jq -r '.patterns[0].url_pattern' "${patterns_path}")"
  [ "${stored}" = "/devices/:id" ] \
    || fail "expected stored url_pattern unchanged (:id, not :itemId or :_); got '${stored}'"
}

@test "memory_record_pattern: canonical match wins over archetype_id mismatch (first archetype_id wins)" {
  # Locked decision: canonical url_pattern is THE idempotency key. If a row
  # exists with the canonical pattern, subsequent records bump hit_count + keep
  # the existing archetype_id, regardless of what archetype_id the new record
  # specifies. This consolidates the common case where _derive_archetype_id
  # gave two agents different archetype names for the same URL family.
  memory_record_pattern prod-app '/devices/:id' devices-id
  memory_record_pattern prod-app '/devices/:itemId' devices-itemid

  patterns_path="${BROWSER_SKILL_HOME}/memory/prod-app/patterns.json"
  rows="$(jq '.patterns | length' "${patterns_path}")"
  [ "${rows}" = "1" ] || fail "expected canonical match to keep 1 row; got ${rows}: $(cat "${patterns_path}")"
  arch="$(jq -r '.patterns[0].archetype_id' "${patterns_path}")"
  [ "${arch}" = "devices-id" ] || fail "expected first-written archetype_id 'devices-id'; got '${arch}'"
}

@test "memory_record_pattern: non-equivalent patterns (different paths) still create separate rows" {
  memory_record_pattern prod-app '/devices/:id' devices-detail
  memory_record_pattern prod-app '/users/:id' users-detail

  patterns_path="${BROWSER_SKILL_HOME}/memory/prod-app/patterns.json"
  rows="$(jq '.patterns | length' "${patterns_path}")"
  [ "${rows}" = "2" ] \
    || fail "different path → different row; got ${rows}: $(cat "${patterns_path}")"
}

@test "memory_resolve_archetype: matches URL when stored pattern uses different :NAME (regression — resolver already param-agnostic)" {
  # The resolver compiles `:NAME` → `[^/]+` regardless of name; this test
  # pins that property as a regression net for the canonicalization PR.
  memory_record_pattern prod-app '/devices/:itemId' devices-detail
  arch="$(memory_resolve_archetype prod-app 'https://prod.example.com/devices/123')"
  [ "${arch}" = "devices-detail" ] \
    || fail "URL should resolve regardless of stored param name; got '${arch}'"
}

# --- self-heal: memory_record on existing disabled intent resets fail_count + disabled ---

@test "memory_record (self-heal): re-record on disabled intent resets fail_count:0 + disabled:false; bumps success_count" {
  memory_save_archetype prod-app devices-detail "$(_arch_json devices-detail '/devices/:id')"
  memory_record prod-app devices-detail "click save" "old.selector"
  # Drive into disabled state via 4 consecutive failures.
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"
  memory_record_failure prod-app devices-detail "click save"

  arch_path="${BROWSER_SKILL_HOME}/memory/prod-app/archetypes/devices-detail.json"
  jq -e '.interactions[0].disabled == true and .interactions[0].fail_count == 4' \
    "${arch_path}" >/dev/null || fail "precondition: expected disabled:true + fail_count:4"

  # Agent re-resolves; record overwrites the disabled entry with a fresh selector.
  memory_record prod-app devices-detail "click save" "new.selector"

  jq -e '
    .interactions | length == 1 and
    .[0].selector == "new.selector" and
    .[0].fail_count == 0 and
    .[0].disabled == false and
    .[0].success_count == 2
  ' "${arch_path}" >/dev/null || fail "expected reset shape; got $(jq -c '.interactions' "${arch_path}")"
}
