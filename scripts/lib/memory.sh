# shellcheck shell=bash
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
  local site_dir
  site_dir="$(_memory_site_dir "${site}")"
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
            #
            # Pick A5: log the disabled→enabled transition. Check BEFORE
            # resetting so the entry can capture the pre-reset fail_count.
            | (if (.disabled // false) == true then
                 .self_heal_history = ((.self_heal_history // []) + [{
                   ts: $now, event: "healed",
                   fail_count: (.fail_count // 0),
                   selector_at_time: $sel
                 }])
               else . end)
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
        # Pick A5: log the enabled→disabled transition (single-shot). Append
        # ONLY when the new fail_count crosses the threshold AND the prior
        # .disabled was not already true. Subsequent failures past the
        # threshold do not double-log.
        | (if (.fail_count > 3) and ((.disabled // false) == false) then
             .self_heal_history = ((.self_heal_history // []) + [{
               ts: $now, event: "disabled",
               fail_count: .fail_count,
               selector_at_time: .selector
             }])
           else . end)
        | .disabled = (.fail_count > 3)
      else . end
    ))
  ' "${path}")"
  memory_save_archetype "${site}" "${id}" "${updated}"
}

# --- Pattern I/O ---

# memory_record_pattern SITE URL_PATTERN ARCHETYPE_ID
# Upserts a (url_pattern, archetype_id) pair into <site>/patterns.json.
# Idempotent: same canonical url_pattern → bumps last_seen + hit_count.
#
# Pick A4 — pattern-equivalence canonicalization: `:NAME` segments differ
# in name (`/devices/:id` vs `/devices/:itemId`) but describe the SAME URL
# family. Idempotency uses the CANONICAL form (`:NAME` → `:_` collapse)
# for compare; the original url_pattern + archetype_id are preserved in
# storage (first-write wins on canonical match — subsequent records bump
# hit_count, archetype_id unchanged even if new record specified a
# different one).
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
    # Pick A4: canonical-pattern helper. Collapses all `:NAME` segments to
    # `:_` so /devices/:id and /devices/:itemId match on compare. The regex
    # mirrors the JS resolver helper (`/:[A-Za-z_][\w$]*/g`).
    def _canonical: gsub(":[A-Za-z_][A-Za-z0-9_]*"; ":_");
    ($p | _canonical) as $pc
    | if ((.patterns // []) | map(select((.url_pattern | _canonical) == $pc)) | length) > 0 then
        .patterns |= map(
          if (.url_pattern | _canonical) == $pc then
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

# --- Pick A6: passive navigation observation log (recent_urls.jsonl) ---

# memory_record_recent_url SITE URL VERB
# Append one observation row to ${BROWSER_SKILL_HOME}/memory/recent_urls.jsonl
# (mode 0600 in mode 0700 memory/). Shape: {ts, url, verb, site, schema_version:1}.
# Best-effort writer — failure emits warn: and continues; never taints caller
# exit code. Same convention as browser-do.sh::_record_event (PR #115 events.jsonl).
#
# Schema starts at v1 from inception; no migrator needed until shape changes.
# (lib/migrators/recent_urls/ stays empty until a future bump.)
memory_record_recent_url() {
  local site="$1" url="$2" verb="$3"
  local events_dir events_file ts line
  events_dir="$(_memory_dir)"
  events_file="${events_dir}/recent_urls.jsonl"
  ts="$(now_iso)"

  if ! mkdir -p "${events_dir}" 2>/dev/null; then
    warn "memory_record_recent_url: mkdir failed (best-effort; navigation unaffected)"
    return 0
  fi
  chmod 700 "${events_dir}" 2>/dev/null || true

  if ! line="$(jq -nc \
      --arg ts "${ts}" --arg url "${url}" --arg verb "${verb}" --arg site "${site}" \
      '{ts:$ts, url:$url, verb:$verb, site:$site, schema_version:1}' 2>/dev/null)"; then
    warn "memory_record_recent_url: encode failed (best-effort; navigation unaffected)"
    return 0
  fi

  # O_APPEND atomicity for short JSON lines (well below PIPE_BUF 4KB).
  if ! printf '%s\n' "${line}" >> "${events_file}" 2>/dev/null; then
    warn "memory_record_recent_url: append failed (best-effort; navigation unaffected)"
    return 0
  fi
  chmod 600 "${events_file}" 2>/dev/null || true
}

# --- Phase 13: weak-fingerprint selector rescue --------------------------

# _memory_parse_selector_to_fp SELECTOR
# Echo a JSON fingerprint {tag, classes, attrs} derived from a CSS selector
# string. "Weak" — handles the common shapes recorded by browser-do record:
# `tag`, `tag.class`, `tag.class1.class2`, `#id`, `[name=value]`, mixed.
# Combinators (`>`, `+`, `~`), pseudo-classes (`:hover`), attribute operators
# (`^=`, `*=`, etc.) are not parsed — the resulting fingerprint will simply be
# weaker, and the JS scorer falls back gracefully (score < threshold = miss).
_memory_parse_selector_to_fp() {
  local sel="$1"
  local tag="*" id="" classes=()
  if [[ "${sel}" =~ ^([a-zA-Z][a-zA-Z0-9]*) ]]; then
    tag="${BASH_REMATCH[1]^^}"
  fi
  local rest="${sel}"
  while [[ "${rest}" =~ \.([A-Za-z][A-Za-z0-9_-]*) ]]; do
    classes+=("${BASH_REMATCH[1]}")
    rest="${rest/${BASH_REMATCH[0]}/}"
  done
  if [[ "${sel}" =~ \#([A-Za-z][A-Za-z0-9_-]*) ]]; then
    id="${BASH_REMATCH[1]}"
  fi
  local classes_json="[]"
  if [ "${#classes[@]}" -gt 0 ]; then
    classes_json="$(printf '%s\n' "${classes[@]}" | jq -R . | jq -sc .)"
  fi
  jq -nc --arg tag "${tag}" --arg id "${id}" --argjson cls "${classes_json}" '
    {tag: $tag,
     classes: $cls,
     attrs: (if $id != "" then {id: $id} else {} end)}'
}

# memory_fingerprint_rescue SITE ARCHETYPE_ID INTENT CACHED_SELECTOR
# Echo the rescued selector on hit, empty on miss. Best-effort — failures emit
# warn: and return 0 without rescuing.
# Threshold defaults to 0.70; override per-session via BROWSER_DO_RESCUE_THRESHOLD.
# Algorithm + selector synthesis lives in scripts/lib/fingerprint-rescue.js.
# SITE/ARCHETYPE/INTENT are reserved for future strong-fingerprint mode that
# reads archetype-stored fingerprint dimensions; the weak v1 only needs the
# cached selector itself.
memory_fingerprint_rescue() {
  local site="$1" archetype="$2" intent="$3" cached_selector="$4"
  : "${site}" "${archetype}" "${intent}"  # silence SC2034 — strong-fp v2 will use
  local threshold="${BROWSER_DO_RESCUE_THRESHOLD:-0.70}"
  local script_dir lib_dir js_template js_payload
  lib_dir="$(dirname "${BASH_SOURCE[0]}")"
  script_dir="$(cd "${lib_dir}/.." && pwd)"
  js_template="${lib_dir}/fingerprint-rescue.js"
  [ -f "${js_template}" ] || { warn "memory_fingerprint_rescue: missing ${js_template}"; return 0; }

  local fp_json
  fp_json="$(_memory_parse_selector_to_fp "${cached_selector}" 2>/dev/null || printf '')"
  [ -z "${fp_json}" ] && return 0

  # Prepend the two constants the JS payload reads.
  js_payload="const __FP=${fp_json};const __TH=${threshold};$(cat "${js_template}")"

  # Invoke browser-extract --eval; capture stdout. Best-effort — adapter
  # failure / no daemon / no current page → empty rescue, fall through to
  # the existing fail_count path.
  local out
  if ! out="$(bash "${script_dir}/browser-extract.sh" --eval "${js_payload}" 2>/dev/null)"; then
    return 0
  fi

  # Streaming output: pick the line carrying {rescued_selector:...}. Tolerant
  # of multiple lines (events + summary); jq returns empty if the field is null.
  local rescued
  rescued="$(printf '%s\n' "${out}" \
    | jq -rs '
        map(select(type=="object" and has("rescued_selector"))) as $hits
        | if ($hits | length) == 0 then ""
          else
            ($hits | last) as $h
            | if ($h.rescued_selector == null) then ""
              else $h.rescued_selector end
          end' 2>/dev/null || printf '')"
  printf '%s' "${rescued}"
}

# memory_record_heal SITE ARCHETYPE_ID INTENT FROM_SELECTOR TO_SELECTOR
# Overwrite an interaction's cached selector after a successful fingerprint
# rescue + retry. Resets fail_count, bumps success_count, appends a "rescued"
# entry to self_heal_history. Distinct from memory_record so the audit trail
# can tell LLM-resolution (memory_record) from pre-LLM fingerprint rescue
# (memory_record_heal).
memory_record_heal() {
  local site="$1" id="$2" intent="$3" from_sel="$4" to_sel="$5"
  local path now updated
  path="$(_memory_archetype_path "${site}" "${id}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_USAGE_ERROR}" "memory_record_heal: archetype not found: ${site}/${id}"
  fi
  now="$(now_iso)"
  updated="$(jq --arg intent "${intent}" --arg from "${from_sel}" \
                --arg to "${to_sel}" --arg now "${now}" '
    .interactions = ((.interactions // []) | map(
      if .intent == $intent then
        .selector = $to
        | .last_used = $now
        | .success_count = ((.success_count // 0) + 1)
        | .fail_count = 0
        | .disabled = false
        | .self_heal_history = ((.self_heal_history // []) + [{
            ts: $now,
            event: "rescued",
            from_selector: $from,
            to_selector: $to
          }])
      else . end
    ))
    | .last_seen = $now
    | .use_count = ((.use_count // 0) + 1)
  ' "${path}")"
  memory_save_archetype "${site}" "${id}" "${updated}"
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
