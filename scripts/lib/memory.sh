# scripts/lib/memory.sh
# Phase 11 part 1-i — per-archetype selector/action cache I/O foundation.
# Pure read/write API; no verb integration (deferred to 11-1-ii browser-do).
# Storage shape per design doc 2026-05-08-phase-11-memory-design.md §4.
#
# Requires lib/common.sh sourced first (init_paths must have run; uses
# BROWSER_SKILL_HOME, file_mode, now_iso, assert_safe_name, die, EXIT_*).

[ -n "${BROWSER_SKILL_MEMORY_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_MEMORY_LOADED=1

# --- Internal path helpers (memory-scoped; not exported to common.sh) ---

_memory_dir() {
  printf '%s/memory' "${BROWSER_SKILL_HOME}"
}

_memory_site_dir() {
  printf '%s/%s' "$(_memory_dir)" "$1"
}

_memory_patterns_path() {
  printf '%s/patterns.json' "$(_memory_site_dir "$1")"
}

_memory_archetype_path() {
  printf '%s/archetypes/%s.json' "$(_memory_site_dir "$1")" "$2"
}

_memory_node_resolver_path() {
  local lib_dir
  lib_dir="$(dirname "${BASH_SOURCE[0]}")"
  printf '%s/node/url-pattern-resolver.mjs' "${lib_dir}"
}

# --- Init ---

# memory_init_dir
# mkdir -p ${BROWSER_SKILL_HOME}/memory + chmod 700. Idempotent.
# Lazy-creation pattern (mirror Phase 7 captures/, Phase 9-1-v baselines.json).
memory_init_dir() {
  local dir
  dir="$(_memory_dir)"
  mkdir -p "${dir}"
  chmod 700 "${dir}"
}

# Internal: ensure per-site dir + archetypes/ subdir exist with mode 0700.
_memory_ensure_site_dir() {
  local site="$1"
  memory_init_dir
  local site_dir="$(_memory_site_dir "${site}")"
  mkdir -p "${site_dir}/archetypes"
  chmod 700 "${site_dir}" "${site_dir}/archetypes"
}

# Internal: atomic JSON write at PATH with mode 0600.
_memory_write_json() {
  local path="$1" json="$2"
  local tmp="${path}.tmp.$$"
  ( umask 077; printf '%s\n' "${json}" | jq . > "${tmp}" )
  chmod 600 "${tmp}"
  mv "${tmp}" "${path}"
}

# --- Archetype I/O ---

# memory_load_archetype SITE ARCHETYPE_ID
# Echoes the archetype JSON exactly as on disk, or empty string if missing.
memory_load_archetype() {
  local path
  path="$(_memory_archetype_path "$1" "$2")"
  if [ -f "${path}" ]; then
    cat "${path}"
  fi
}

# memory_save_archetype SITE ARCHETYPE_ID JSON
# Validates JSON, atomic-writes mode 0600. Caller is responsible for shape;
# this lib only validates "is it valid JSON".
memory_save_archetype() {
  local site="$1" id="$2" json="$3"
  assert_safe_name "${site}" "site-name"
  assert_safe_name "${id}" "archetype-id"
  if ! printf '%s' "${json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "memory_save_archetype: invalid JSON"
  fi
  _memory_ensure_site_dir "${site}"
  _memory_write_json "$(_memory_archetype_path "${site}" "${id}")" "${json}"
}

# --- Lookup ---

# memory_lookup SITE ARCHETYPE_ID INTENT
# Echoes the cached selector for (site, archetype, intent), or empty on miss.
# Disabled interactions (self-heal) are skipped — they're effectively absent
# from the cache until 11-1-iii's loop re-resolves and overwrites.
memory_lookup() {
  local path
  path="$(_memory_archetype_path "$1" "$2")"
  [ -f "${path}" ] || return 0
  jq -r --arg intent "$3" '
    (.interactions // [])
    | map(select(.intent == $intent and (.disabled // false) == false))
    | if length == 0 then "" else .[0].selector end
  ' "${path}"
}

# --- Recording ---

# memory_record SITE ARCHETYPE_ID INTENT SELECTOR
# Upserts an interaction. New intent → first_used+last_used set, success_count:1,
# fail_count:0, disabled:false, self_heal_history:[]. Existing intent →
# selector overwritten, last_used advances, success_count++; first_used preserved.
# Bumps archetype's use_count + last_seen.
memory_record() {
  local site="$1" id="$2" intent="$3" selector="$4"
  local path now updated
  path="$(_memory_archetype_path "${site}" "${id}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_USAGE_ERROR}" "memory_record: archetype not found: ${site}/${id}"
  fi
  now="$(now_iso)"
  updated="$(jq --arg intent "${intent}" --arg sel "${selector}" --arg now "${now}" '
    .interactions = (
      if ((.interactions // []) | map(select(.intent == $intent)) | length) > 0 then
        (.interactions | map(
          if .intent == $intent then
            .selector = $sel
            | .last_used = $now
            | .success_count = (.success_count + 1)
            # Self-heal (Phase 11 1-iii D2): a successful re-record clears
            # any prior failure state. This is what "agent re-resolved →
            # cache heals" means at the storage layer.
            | .fail_count = 0
            | .disabled = false
          else . end
        ))
      else
        ((.interactions // []) + [{
          intent: $intent, selector: $sel,
          first_used: $now, last_used: $now,
          success_count: 1, fail_count: 0,
          disabled: false, self_heal_history: []
        }])
      end
    )
    | .last_seen = $now
    | .use_count = ((.use_count // 0) + 1)
  ' "${path}")"
  memory_save_archetype "${site}" "${id}" "${updated}"
}

# memory_record_failure SITE ARCHETYPE_ID INTENT
# Increments fail_count on the matching interaction. Sets disabled:true once
# fail_count > 3 (H1 threshold from design doc §3). No-op if intent absent —
# callers should only invoke after a lookup hit.
memory_record_failure() {
  local site="$1" id="$2" intent="$3"
  local path now updated
  path="$(_memory_archetype_path "${site}" "${id}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_USAGE_ERROR}" "memory_record_failure: archetype not found: ${site}/${id}"
  fi
  now="$(now_iso)"
  updated="$(jq --arg intent "${intent}" --arg now "${now}" '
    .interactions = ((.interactions // []) | map(
      if .intent == $intent then
        .fail_count = ((.fail_count // 0) + 1)
        | .last_used = $now
        | .disabled = (.fail_count > 3)
      else . end
    ))
  ' "${path}")"
  memory_save_archetype "${site}" "${id}" "${updated}"
}

# --- Pattern I/O ---

# memory_record_pattern SITE URL_PATTERN ARCHETYPE_ID
# Upserts a (url_pattern, archetype_id) pair into <site>/patterns.json.
# Idempotent: same pair → bumps last_seen + hit_count, doesn't duplicate.
memory_record_pattern() {
  local site="$1" url_pattern="$2" arch_id="$3"
  assert_safe_name "${site}" "site-name"
  assert_safe_name "${arch_id}" "archetype-id"
  _memory_ensure_site_dir "${site}"

  local patterns_path now current updated
  patterns_path="$(_memory_patterns_path "${site}")"
  now="$(now_iso)"

  if [ -f "${patterns_path}" ]; then
    current="$(cat "${patterns_path}")"
  else
    current='{"schema_version":1,"patterns":[]}'
  fi

  updated="$(printf '%s' "${current}" | jq \
    --arg p "${url_pattern}" --arg arch "${arch_id}" --arg now "${now}" '
    if ((.patterns // []) | map(select(.url_pattern == $p and .archetype_id == $arch)) | length) > 0 then
      .patterns |= map(
        if .url_pattern == $p and .archetype_id == $arch then
          .last_seen = $now | .hit_count = ((.hit_count // 0) + 1)
        else . end
      )
    else
      .patterns = ((.patterns // []) + [{
        url_pattern: $p, archetype_id: $arch,
        first_seen: $now, last_seen: $now, hit_count: 1
      }])
    end
  ')"

  _memory_write_json "${patterns_path}" "${updated}"
}

# memory_resolve_archetype SITE URL
# Echoes the archetype_id for the first matching url_pattern in <site>/patterns.json.
# Empty on miss (or if patterns.json is absent). URLPattern resolution is
# delegated to scripts/lib/node/url-pattern-resolver.mjs (Node 20+ web standard).
memory_resolve_archetype() {
  local site="$1" url="$2"
  local patterns_path
  patterns_path="$(_memory_patterns_path "${site}")"
  [ -f "${patterns_path}" ] || return 0

  local input result
  input="$(jq -nc --slurpfile p "${patterns_path}" --arg url "${url}" \
    '{patterns: ($p[0].patterns // []), url: $url}')"
  result="$(printf '%s' "${input}" | node "$(_memory_node_resolver_path)")"
  if [ -n "${result}" ] && [ "${result}" != "null" ]; then
    printf '%s' "${result}" | jq -r '.archetype_id // empty'
  fi
}
