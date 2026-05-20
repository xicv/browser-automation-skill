# scripts/lib/capture.sh — capture artifact pipeline (Phase 7 part 1-i).
#
# Three-function API:
#   capture_init_dir          — idempotent mkdir 0700 of ${CAPTURES_DIR}
#   capture_start <verb>      — atomic NNN allocation + meta.json (in_progress)
#   capture_finish [status]   — finalize meta.json + update _index.json
#
# Verbs sandwich their per-aspect file writes between capture_start and
# capture_finish. After capture_start: ${CAPTURE_ID} + ${CAPTURE_DIR} are
# exported; the verb writes any per-aspect files (snapshot.json,
# console.json, network.har, screenshot.png, etc.) into ${CAPTURE_DIR};
# capture_finish recomputes total_bytes + files inventory.
#
# 7-i scope: no sanitization (7-iii), no retention/prune (7-v), no
# --unsanitized (7-iv). Wired only to snapshot — structurally safe (no
# headers, no cookies). Sanitization arrives when console.json + network.har
# enter the picture.
#
# Atomicity: NNN allocation uses tmpfile + rename(2) per parent spec §4.5
# ("tmpfile + mv, no flock"). Single-process per invocation expected; two
# concurrent capture_starts could race on the same NNN. v1 design doesn't
# pay flock complexity. Future hardening: mkdir without -p so the second
# loser fails fast → retry with bumped id.

[ -n "${_BROWSER_LIB_CAPTURE_LOADED:-}" ] && return 0
readonly _BROWSER_LIB_CAPTURE_LOADED=1

# capture_init_dir
#   Ensure ${CAPTURES_DIR} exists, mode 0700. No-op if already correct.
capture_init_dir() {
  if [ ! -d "${CAPTURES_DIR}" ]; then
    mkdir -p "${CAPTURES_DIR}"
    chmod 700 "${CAPTURES_DIR}"
  fi
}

# _capture_iso_now — UTC ISO 8601, second precision. Cross-platform.
_capture_iso_now() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# _capture_iso_to_epoch — ISO 8601 string → epoch seconds. GNU date first
# (Linux + coreutils-installed-Mac); BSD date fallback. Returns 0 on parse
# failure (caller treats 0 as "very old", which is safe for prune logic).
_capture_iso_to_epoch() {
  local iso="$1"
  date -d "${iso}" +%s 2>/dev/null \
    || date -j -f '%Y-%m-%dT%H:%M:%SZ' "${iso}" +%s 2>/dev/null \
    || printf '0'
}

# _capture_now_epoch — current epoch seconds.
# Honors BROWSER_SKILL_CAPTURE_NOW_EPOCH (test-only seam) so age-threshold
# tests can anchor to a fixed wall-clock and survive calendar drift. Without
# the override the prod code path remains a single `date +%s` fork.
_capture_now_epoch() {
  if [ -n "${BROWSER_SKILL_CAPTURE_NOW_EPOCH:-}" ]; then
    printf '%s\n' "${BROWSER_SKILL_CAPTURE_NOW_EPOCH}"
  else
    date +%s
  fi
}

# _capture_read_config — emits {retention_count, retention_days, warn_at_pct}
# from ${CONFIG_FILE}, falling back to spec §4.5 defaults on missing file or
# missing fields.
_capture_read_config() {
  if [ -f "${CONFIG_FILE}" ]; then
    jq '{
      retention_count: (.retention_count // 500),
      retention_days:  (.retention_days  // 14),
      warn_at_pct:     (.warn_at_pct     // 90)
    }' "${CONFIG_FILE}" 2>/dev/null \
      || printf '{"retention_count":500,"retention_days":14,"warn_at_pct":90}'
  else
    printf '{"retention_count":500,"retention_days":14,"warn_at_pct":90}'
  fi
}

# _capture_pad_id N → "001" (3-digit zero-padded; %d at >=1000)
_capture_pad_id() {
  local n="$1"
  if [ "${n}" -lt 1000 ]; then
    printf '%03d' "${n}"
  else
    printf '%d' "${n}"
  fi
}

# _capture_read_next_id → echoes the next unused integer id.
# Reads ${CAPTURES_DIR}/_index.json; defaults to 1 if absent or unreadable.
_capture_read_next_id() {
  local idx="${CAPTURES_DIR}/_index.json"
  if [ -f "${idx}" ]; then
    jq -r '.next_id // 1' "${idx}" 2>/dev/null || printf '1'
  else
    printf '1'
  fi
}

# _capture_write_index <next_id> <count> <latest> <total_bytes>
#   Atomic write via tmpfile + mv (same FS guarantees rename(2) atomicity).
_capture_write_index() {
  local next_id="$1" count="$2" latest="$3" total_bytes="$4"
  local idx="${CAPTURES_DIR}/_index.json"
  local tmp="${idx}.tmp.$$"
  jq -n \
    --argjson schema_version 1 \
    --argjson next_id "${next_id}" \
    --argjson count "${count}" \
    --arg     latest "${latest}" \
    --argjson total_bytes "${total_bytes}" \
    '{schema_version: $schema_version, next_id: $next_id, count: $count, latest: $latest, total_bytes: $total_bytes}' \
    > "${tmp}"
  chmod 600 "${tmp}"
  mv "${tmp}" "${idx}"
}

# capture_start <verb>
#   Allocates the next NNN, mkdir 0700, writes meta.json (status=in_progress),
#   bumps _index.next_id, exports CAPTURE_ID + CAPTURE_DIR.
capture_start() {
  local verb="${1:-unknown}"
  capture_init_dir

  local next_id padded
  next_id="$(_capture_read_next_id)"
  padded="$(_capture_pad_id "${next_id}")"

  CAPTURE_ID="${padded}"
  CAPTURE_DIR="${CAPTURES_DIR}/${padded}"
  export CAPTURE_ID CAPTURE_DIR

  mkdir -p "${CAPTURE_DIR}"
  chmod 700 "${CAPTURE_DIR}"

  local meta="${CAPTURE_DIR}/meta.json"
  local tmp="${meta}.tmp.$$"
  jq -n \
    --arg     capture_id "${padded}" \
    --arg     verb "${verb}" \
    --argjson schema_version 1 \
    --arg     started_at "$(_capture_iso_now)" \
    --arg     status "in_progress" \
    '{capture_id: $capture_id, verb: $verb, schema_version: $schema_version, started_at: $started_at, status: $status}' \
    > "${tmp}"
  chmod 600 "${tmp}"
  mv "${tmp}" "${meta}"

  # Bump _index.next_id immediately (allocation-time bump). count + latest +
  # total_bytes will be authoritative after capture_finish; for now hold the
  # prior values where present. New _index gets count=0 here; capture_finish
  # increments it.
  local idx="${CAPTURES_DIR}/_index.json"
  local count latest total_bytes
  if [ -f "${idx}" ]; then
    count="$(jq -r '.count // 0' "${idx}" 2>/dev/null || printf '0')"
    latest="$(jq -r '.latest // ""' "${idx}" 2>/dev/null || printf '')"
    total_bytes="$(jq -r '.total_bytes // 0' "${idx}" 2>/dev/null || printf '0')"
  else
    count=0
    latest=""
    total_bytes=0
  fi
  _capture_write_index "$((next_id + 1))" "${count}" "${latest}" "${total_bytes}"
}

# _capture_file_size <path> → byte count (cross-platform).
_capture_file_size() {
  local p="$1"
  stat -c '%s' "${p}" 2>/dev/null || stat -f '%z' "${p}" 2>/dev/null || printf '0'
}

# _capture_inventory <dir> → JSON array of {name, bytes} for every regular file
#   in <dir> (sorted by name). meta.json is NOT excluded — its size is part of
#   total_bytes. Subdirectories (downloads/) handled in a future sub-part.
_capture_inventory() {
  local dir="$1"
  local entries=()
  local f name bytes
  # /usr/bin/find avoids any rtk fff aliasing.
  while IFS= read -r f; do
    name="$(basename "${f}")"
    bytes="$(_capture_file_size "${f}")"
    entries+=("$(jq -n --arg name "${name}" --argjson bytes "${bytes}" '{name: $name, bytes: $bytes}')")
  done < <(/usr/bin/find "${dir}" -maxdepth 1 -type f | sort)

  if [ "${#entries[@]}" -eq 0 ]; then
    printf '[]'
  else
    printf '%s\n' "${entries[@]}" | jq -s '.'
  fi
}

# capture_finish [status] [sanitized]
#   Default status: "ok". Default sanitized: "true".
#   Updates meta.json (finished_at, status, sanitized, total_bytes, files);
#   updates _index.json (count, latest, total_bytes).
#
# Phase 7 part 1-iv: optional 2nd arg `sanitized` ∈ {true, false}. Writes
# meta.sanitized field for audit. Field is always present in v1+ schema;
# default true matches the sanitized-by-default contract.
capture_finish() {
  local status="${1:-ok}"
  local sanitized="${2:-true}"
  : "${CAPTURE_DIR:?capture_finish: CAPTURE_DIR not set (call capture_start first)}"
  : "${CAPTURE_ID:?capture_finish: CAPTURE_ID not set (call capture_start first)}"

  local meta="${CAPTURE_DIR}/meta.json"
  [ -f "${meta}" ] || die "${EXIT_GENERIC_ERROR:-1}" "capture_finish: meta.json missing for ${CAPTURE_ID}"

  local files_json total_bytes
  files_json="$(_capture_inventory "${CAPTURE_DIR}")"
  total_bytes="$(printf '%s' "${files_json}" | jq '[.[].bytes] | add // 0')"

  local tmp="${meta}.tmp.$$"
  jq \
    --arg     finished_at "$(_capture_iso_now)" \
    --arg     status "${status}" \
    --argjson sanitized "${sanitized}" \
    --argjson total_bytes "${total_bytes}" \
    --argjson files "${files_json}" \
    '. + {finished_at: $finished_at, status: $status, sanitized: $sanitized, total_bytes: $total_bytes, files: $files}' \
    "${meta}" > "${tmp}"
  chmod 600 "${tmp}"
  mv "${tmp}" "${meta}"

  # Update _index.json: count is the count of capture dirs on disk; latest is
  # this CAPTURE_ID; total_bytes is the sum across all capture dirs (cached
  # for doctor UX). Pruning will keep this honest in 7-v.
  local idx="${CAPTURES_DIR}/_index.json"
  local next_id
  if [ -f "${idx}" ]; then
    next_id="$(jq -r '.next_id // 1' "${idx}" 2>/dev/null || printf '1')"
  else
    next_id=1
  fi
  local on_disk_count
  on_disk_count="$(/usr/bin/find "${CAPTURES_DIR}" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
  local on_disk_total
  on_disk_total="$(/usr/bin/find "${CAPTURES_DIR}" -mindepth 2 -type f -exec stat -c '%s' {} + 2>/dev/null \
                   || /usr/bin/find "${CAPTURES_DIR}" -mindepth 2 -type f -exec stat -f '%z' {} + 2>/dev/null \
                   || printf '')"
  local on_disk_total_sum
  on_disk_total_sum="$(printf '%s\n' "${on_disk_total}" | awk '{s+=$1} END {print s+0}')"

  _capture_write_index "${next_id}" "${on_disk_count}" "${CAPTURE_ID}" "${on_disk_total_sum}"

  # Phase 7 part 1-v: auto-prune at the end of every successful finalize.
  # Idempotent — no-op when state is under thresholds.
  capture_prune
}

# capture_prune (Phase 7 part 1-v)
#   Reads ${CONFIG_FILE} thresholds (defaults if missing/null per spec §4.5).
#   Walks ${CAPTURES_DIR}/*/meta.json; computes age + count.
#   Splices oldest-first while EITHER threshold exceeded.
#   Skip rules:
#     - meta.is_baseline == true   (Phase 8 forward-compat — never prune)
#     - meta.status == "in_progress" (in-flight; never prune)
#   After prune: recomputes _index.json (count, latest, total_bytes).
#   Idempotent.
capture_prune() {
  [ -d "${CAPTURES_DIR}" ] || return 0

  local config retention_count retention_days
  config="$(_capture_read_config)"
  retention_count="$(printf '%s' "${config}" | jq -r '.retention_count')"
  retention_days="$(printf '%s' "${config}" | jq -r '.retention_days')"

  local now_epoch age_threshold_sec
  now_epoch="$(_capture_now_epoch)"
  age_threshold_sec=$(( retention_days * 86400 ))

  # Build sorted (oldest-first) prunable-id list.
  # Format: "<epoch>\t<id>\t<is_baseline>\t<status>"
  local entries
  entries="$(
    /usr/bin/find "${CAPTURES_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
      | while read -r dir; do
          local id meta started_at started_epoch is_baseline status
          id="$(basename "${dir}")"
          meta="${dir}/meta.json"
          [ -f "${meta}" ] || continue
          started_at="$(jq -r '.started_at // ""' "${meta}" 2>/dev/null)"
          [ -n "${started_at}" ] || continue
          started_epoch="$(_capture_iso_to_epoch "${started_at}")"
          is_baseline="$(jq -r '.is_baseline // false' "${meta}" 2>/dev/null || printf 'false')"
          status="$(jq -r '.status // "in_progress"' "${meta}" 2>/dev/null || printf 'in_progress')"
          printf '%s\t%s\t%s\t%s\n' "${started_epoch}" "${id}" "${is_baseline}" "${status}"
        done \
      | sort -n
  )"

  [ -n "${entries}" ] || return 0

  # First pass: collect prunable + protected counts.
  local total_count protected_count prunable_count
  total_count="$(printf '%s\n' "${entries}" | wc -l | tr -d ' ')"
  protected_count="$(printf '%s\n' "${entries}" | awk -F'\t' '$3 == "true" || $4 == "in_progress"' | wc -l | tr -d ' ')"
  prunable_count=$(( total_count - protected_count ))

  # Walk oldest-first; prune while either threshold exceeded AND entry is prunable.
  local pruned_any=0
  while IFS=$'\t' read -r entry_epoch entry_id entry_baseline entry_status; do
    [ -n "${entry_id}" ] || continue
    # Skip protected.
    if [ "${entry_baseline}" = "true" ] || [ "${entry_status}" = "in_progress" ]; then
      continue
    fi
    # Should we prune this one?
    local age_sec=$(( now_epoch - entry_epoch ))
    local exceeds_count=0 exceeds_age=0
    if [ "${total_count}" -gt "${retention_count}" ]; then
      exceeds_count=1
    fi
    if [ "${age_sec}" -gt "${age_threshold_sec}" ]; then
      exceeds_age=1
    fi
    if [ "${exceeds_count}" = "0" ] && [ "${exceeds_age}" = "0" ]; then
      # Under both thresholds — stop (subsequent entries are newer).
      break
    fi
    # Prune.
    rm -rf "${CAPTURES_DIR:?}/${entry_id}"
    warn "capture_prune: pruned captures/${entry_id}/ (age=${age_sec}s, baseline=${entry_baseline})" >&2
    pruned_any=1
    total_count=$(( total_count - 1 ))
  done <<< "${entries}"

  # Recompute _index.json post-prune.
  if [ "${pruned_any}" = "1" ]; then
    local idx="${CAPTURES_DIR}/_index.json"
    local next_id
    if [ -f "${idx}" ]; then
      next_id="$(jq -r '.next_id // 1' "${idx}" 2>/dev/null || printf '1')"
    else
      next_id=1
    fi
    local on_disk_count
    on_disk_count="$(/usr/bin/find "${CAPTURES_DIR}" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
    local on_disk_total
    on_disk_total="$(/usr/bin/find "${CAPTURES_DIR}" -mindepth 2 -type f -exec stat -c '%s' {} + 2>/dev/null \
                     || /usr/bin/find "${CAPTURES_DIR}" -mindepth 2 -type f -exec stat -f '%z' {} + 2>/dev/null \
                     || printf '')"
    local on_disk_total_sum
    on_disk_total_sum="$(printf '%s\n' "${on_disk_total}" | awk '{s+=$1} END {print s+0}')"

    # Latest = highest-id surviving capture (lexicographic on padded NNN).
    local latest_id
    latest_id="$(/usr/bin/find "${CAPTURES_DIR}" -maxdepth 1 -mindepth 1 -type d | xargs -I{} basename {} | sort -r | head -1)"
    [ -n "${latest_id}" ] || latest_id=""

    _capture_write_index "${next_id}" "${on_disk_count}" "${latest_id}" "${on_disk_total_sum}"
  fi
}
