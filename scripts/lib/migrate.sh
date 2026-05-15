# shellcheck shell=bash
# scripts/lib/migrate.sh
# Phase 10 part 1-i — schema migration foundation.
# Per-schema versions in versions.json; per-schema atomic-swap with backup;
# manual rollback. Pure read/write API; no verb integration (10-1-ii) and no
# real migrators registered (10-1-iii).
#
# Per design doc 2026-05-11-phase-10-schema-migration-design.md:
#   MIG1 — per-schema versions (not global)
#   MIG2 — registry directory: scripts/lib/migrators/<schema>/v<from>_to_<to>.sh
#          BROWSER_SKILL_MIGRATORS_DIR env override = test-only seam
#   MIG3 — atomic write + backup; jq -e validation; refuse swap on bad output
#   MIG5 — pure bash + jq; no Node
#
# Requires lib/common.sh sourced first (uses BROWSER_SKILL_HOME, file_mode,
# now_iso, assert_safe_name, die, EXIT_*).

[ -n "${BROWSER_SKILL_MIGRATE_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_MIGRATE_LOADED=1

# --- Constants ---

# Known schemas; versions.json is initialized with all of these at v1 by
# migrate_init when no prior state exists. Adding a new schema = append here +
# add the corresponding entry to versions.json on next migrate_init call.
# Phase 12 part 2: `stats` schema registered for per-action telemetry log
# (memory/stats.jsonl + stats.db). v1 only; v2+ migrators land at
# scripts/lib/migrators/stats/v<from>_to_<to>.sh when shape evolves.
readonly _MIGRATE_KNOWN_SCHEMAS=(sites sessions credentials captures baselines memory config stats)

# Default backup retention.
readonly _MIGRATE_DEFAULT_KEEP=5

# --- Internal path helpers ---

_migrate_versions_path() {
  printf '%s/versions.json' "${BROWSER_SKILL_HOME}"
}

_migrate_legacy_version_path() {
  printf '%s/version' "${BROWSER_SKILL_HOME}"
}

_migrate_backups_dir() {
  printf '%s/backups' "${BROWSER_SKILL_HOME}"
}

_migrate_schema_backups_dir() {
  printf '%s/%s' "$(_migrate_backups_dir)" "$1"
}

_migrate_migrators_dir() {
  if [ -n "${BROWSER_SKILL_MIGRATORS_DIR:-}" ]; then
    printf '%s' "${BROWSER_SKILL_MIGRATORS_DIR}"
    return 0
  fi
  local lib_dir
  lib_dir="$(dirname "${BASH_SOURCE[0]}")"
  printf '%s/migrators' "${lib_dir}"
}

# --- Init ---

# migrate_init
# Lazy-creates versions.json (mode 0600) + backups/ (mode 0700) at the
# canonical state-home paths. Idempotent. If a legacy `version` file exists
# (single integer), reads it and seeds the new versions.json with all known
# schemas at that version (typically 1).
migrate_init() {
  local backups_dir versions_path
  backups_dir="$(_migrate_backups_dir)"
  versions_path="$(_migrate_versions_path)"

  mkdir -p "${backups_dir}"
  chmod 700 "${backups_dir}"

  if [ ! -f "${versions_path}" ]; then
    local default_v=1
    local legacy="$(_migrate_legacy_version_path)"
    if [ -f "${legacy}" ]; then
      default_v="$(tr -d '[:space:]' < "${legacy}" 2>/dev/null || printf '1')"
      [[ "${default_v}" =~ ^[0-9]+$ ]] || default_v=1
    fi
    local schemas_obj
    schemas_obj="$(_migrate_build_default_schemas_object "${default_v}")"
    _migrate_atomic_versions_write "$(jq -nc \
      --argjson v "${default_v}" \
      --argjson schemas "${schemas_obj}" \
      --arg sk "v0.56.0" \
      '{schema_version:1, schema_versions:$schemas, skill_version:$sk}')"
  fi
}

# Internal: build a JSON object {sites:N, sessions:N, ...} for the known schemas.
_migrate_build_default_schemas_object() {
  local v="$1"
  local args=()
  local s
  for s in "${_MIGRATE_KNOWN_SCHEMAS[@]}"; do
    args+=(--argjson "${s}" "${v}")
  done
  local filter='. = {}'
  for s in "${_MIGRATE_KNOWN_SCHEMAS[@]}"; do
    filter="${filter} | .${s} = \$${s}"
  done
  jq -nc "${args[@]}" "${filter}"
}

# --- Versions read/write ---

# migrate_get_version SCHEMA
# Echoes current schema_version for SCHEMA. Returns 1 (default) if SCHEMA is
# absent from versions.json or if versions.json itself is missing.
migrate_get_version() {
  local schema="$1"
  assert_safe_name "${schema}" "schema-name"
  local versions_path
  versions_path="$(_migrate_versions_path)"
  if [ ! -f "${versions_path}" ]; then
    printf '1\n'
    return 0
  fi
  jq -r --arg s "${schema}" '.schema_versions[$s] // 1' "${versions_path}"
}

# migrate_set_version SCHEMA N
# Atomic-write SCHEMA → N in versions.json. Auto-init if versions.json missing.
migrate_set_version() {
  local schema="$1" n="$2"
  assert_safe_name "${schema}" "schema-name"
  [[ "${n}" =~ ^[0-9]+$ ]] || die "${EXIT_USAGE_ERROR}" "migrate_set_version: N must be integer (got: ${n})"
  migrate_init
  local versions_path current updated
  versions_path="$(_migrate_versions_path)"
  current="$(cat "${versions_path}")"
  updated="$(printf '%s' "${current}" | jq -c --arg s "${schema}" --argjson n "${n}" \
    '.schema_versions[$s] = $n')"
  _migrate_atomic_versions_write "${updated}"
}

# Internal: atomic-write versions.json. Validates JSON before swap.
_migrate_atomic_versions_write() {
  local json="$1"
  if ! printf '%s' "${json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_GENERIC_ERROR}" "migrate: refused to write invalid versions.json"
  fi
  local path tmp
  path="$(_migrate_versions_path)"
  tmp="${path}.tmp.$$"
  ( umask 077; printf '%s\n' "${json}" | jq . > "${tmp}" )
  chmod 600 "${tmp}"
  mv "${tmp}" "${path}"
}

# --- Registry ---

# Internal in-process registry table. Keys: "<schema>:<from>:<to>". Values: fn name.
declare -gA _MIGRATE_REGISTRY=()

# _migrate_register SCHEMA FROM TO FN
# Adds FN as the migrator for SCHEMA going from version FROM to version TO.
_migrate_register() {
  local schema="$1" from="$2" to="$3" fn="$4"
  _MIGRATE_REGISTRY["${schema}:${from}:${to}"]="${fn}"
}

# _migrate_load_registry
# Sources every scripts/lib/migrators/*/v*_to_v*.sh under the configured
# migrators dir. Each loaded file is expected to call _migrate_register itself
# OR to define a fn that follows the convention `migrate_<schema>_v<F>_to_v<T>`
# which we auto-register based on the file path.
_migrate_load_registry() {
  local migrators_dir
  migrators_dir="$(_migrate_migrators_dir)"
  [ -d "${migrators_dir}" ] || return 0
  local schema_dir schema migrator_file from to fn
  for schema_dir in "${migrators_dir}"/*; do
    [ -d "${schema_dir}" ] || continue
    schema="$(basename "${schema_dir}")"
    for migrator_file in "${schema_dir}"/v*_to_v*.sh; do
      [ -f "${migrator_file}" ] || continue
      # Parse "v<F>_to_v<T>.sh" out of the basename.
      local base="$(basename "${migrator_file}" .sh)"
      if [[ "${base}" =~ ^v([0-9]+)_to_v([0-9]+)$ ]]; then
        from="${BASH_REMATCH[1]}"
        to="${BASH_REMATCH[2]}"
        # shellcheck disable=SC1090
        source "${migrator_file}"
        fn="migrate_${schema}_v${from}_to_v${to}"
        _migrate_register "${schema}" "${from}" "${to}" "${fn}"
      fi
    done
  done
}

# --- Check ---

# migrate_check
# Walks the registry; for each (schema, from, to) entry where current schema
# version == from, emits a `_kind:migration_needed` event. Always exits 0.
migrate_check() {
  local t0=$(now_ms)
  migrate_init
  _migrate_load_registry

  local pending=0
  local key
  for key in "${!_MIGRATE_REGISTRY[@]}"; do
    local schema="${key%%:*}"
    local rest="${key#*:}"
    local from="${rest%:*}"
    local to="${rest#*:}"
    local current
    current="$(migrate_get_version "${schema}")"
    if [ "${current}" = "${from}" ]; then
      printf '%s\n' "$(jq -nc \
        --arg schema "${schema}" --argjson from "${from}" --argjson to "${to}" \
        '{_kind:"migration_needed", schema:$schema, from:$from, to:$to}')"
      pending=$(( pending + 1 ))
    fi
  done

  local duration_ms=$(( $(now_ms) - t0 ))
  summary_json verb=migrate mode=check pending="${pending}" \
    duration_ms="${duration_ms}" status=ok
}

# --- Run ---

# migrate_run [SCHEMA]
# For each registered migrator (optionally filtered to SCHEMA), if the current
# version matches the migrator's `from`, run it against every file under
# ${BROWSER_SKILL_HOME}/<schema>/ that exists. Validates output via jq -e;
# refuses to atomic-swap on validation failure (version stays at `from`).
# Backs up each file to backups/<schema>/<basename>.bak.v<from> before swap.
migrate_run() {
  local t0=$(now_ms)
  local filter_schema="${1:-}"
  migrate_init
  _migrate_load_registry

  local migrated=0 failed=0
  local key
  for key in "${!_MIGRATE_REGISTRY[@]}"; do
    local schema="${key%%:*}"
    [ -n "${filter_schema}" ] && [ "${schema}" != "${filter_schema}" ] && continue
    local rest="${key#*:}"
    local from="${rest%:*}"
    local to="${rest#*:}"
    local current
    current="$(migrate_get_version "${schema}")"
    [ "${current}" = "${from}" ] || continue

    local fn="${_MIGRATE_REGISTRY[$key]}"
    local schema_state_dir="${BROWSER_SKILL_HOME}/${schema}"
    [ -d "${schema_state_dir}" ] || continue

    # Run migrator against every file in the schema's state dir.
    local file ok=1
    while IFS= read -r -d '' file; do
      _migrate_backup "${schema}" "${file}"
      "${fn}" "${file}" || { ok=0; break; }
      # Validate post-migration JSON.
      if ! jq -e . "${file}" >/dev/null 2>&1; then
        warn "migrate_run: ${schema} migrator produced invalid JSON for ${file}; rolling back this file"
        local bk="$(_migrate_schema_backups_dir "${schema}")/$(basename "${file}").bak.v${from}"
        if [ -f "${bk}" ]; then
          cp "${bk}" "${file}"
        fi
        ok=0
        break
      fi
    done < <(find "${schema_state_dir}" -maxdepth 4 -type f -name '*.json' -print0 2>/dev/null)

    if [ "${ok}" = "1" ]; then
      migrate_set_version "${schema}" "${to}"
      migrated=$(( migrated + 1 ))
      printf '%s\n' "$(jq -nc \
        --arg schema "${schema}" --argjson from "${from}" --argjson to "${to}" \
        '{_kind:"migration_applied", schema:$schema, from:$from, to:$to}')"
    else
      failed=$(( failed + 1 ))
    fi
  done

  local duration_ms=$(( $(now_ms) - t0 ))
  summary_json verb=migrate mode=run migrated="${migrated}" failed="${failed}" \
    duration_ms="${duration_ms}" status=ok
}

# Internal: backup FILE under backups/<schema>/<basename>.bak.v<current_version>.
_migrate_backup() {
  local schema="$1" file="$2"
  local current bk_dir bk
  current="$(migrate_get_version "${schema}")"
  bk_dir="$(_migrate_schema_backups_dir "${schema}")"
  mkdir -p "${bk_dir}"
  chmod 700 "${bk_dir}"
  bk="${bk_dir}/$(basename "${file}").bak.v${current}"
  cp "${file}" "${bk}"
  chmod 600 "${bk}"
}

# --- Rollback ---

# migrate_rollback SCHEMA
# Restores the latest backup for SCHEMA's state-dir files. Single-step only;
# multi-version chains require multiple invocations.
migrate_rollback() {
  local schema="$1"
  assert_safe_name "${schema}" "schema-name"
  migrate_init

  local current bk_dir
  current="$(migrate_get_version "${schema}")"
  bk_dir="$(_migrate_schema_backups_dir "${schema}")"
  [ -d "${bk_dir}" ] || die "${EXIT_USAGE_ERROR}" "migrate_rollback: no backups for schema '${schema}'"

  # Find latest backup version present.
  local latest=0 file v
  while IFS= read -r file; do
    base="$(basename "${file}")"
    v="${base##*.v}"
    [[ "${v}" =~ ^[0-9]+$ ]] || continue
    [ "${v}" -gt "${latest}" ] && latest="${v}"
  done < <(find "${bk_dir}" -maxdepth 1 -type f -name '*.bak.v*' 2>/dev/null)

  [ "${latest}" -gt 0 ] || die "${EXIT_USAGE_ERROR}" "migrate_rollback: no v* backups found for '${schema}'"

  # Restore every file at that version.
  local schema_state_dir="${BROWSER_SKILL_HOME}/${schema}"
  while IFS= read -r file; do
    local target_basename="${file##*/}"
    target_basename="${target_basename%.bak.v*}"
    cp "${file}" "${schema_state_dir}/${target_basename}"
    chmod 600 "${schema_state_dir}/${target_basename}"
  done < <(find "${bk_dir}" -maxdepth 1 -type f -name "*.bak.v${latest}" 2>/dev/null)

  migrate_set_version "${schema}" "${latest}"
}

# --- Status ---

# migrate_status
# Echoes versions.json (after init).
migrate_status() {
  migrate_init
  cat "$(_migrate_versions_path)"
}

# --- Clean backups ---

# migrate_clean_backups [N]
# Discards backups beyond the newest N versions per schema. Default N=5.
#
# Implementation note: uses newline-separated find pipeline (rather than
# space-joined values in an associative array) because callers may run with
# IFS=$'\n\t' set globally — that breaks word-splitting on space inside
# `printf '%s\n' ${array_value}`. Newlines are robust under all IFS settings.
migrate_clean_backups() {
  local keep="${1:-${_MIGRATE_DEFAULT_KEEP}}"
  [[ "${keep}" =~ ^[0-9]+$ ]] || die "${EXIT_USAGE_ERROR}" "migrate_clean_backups: N must be integer (got: ${keep})"
  local backups_dir
  backups_dir="$(_migrate_backups_dir)"
  [ -d "${backups_dir}" ] || return 0

  local schema_dir
  for schema_dir in "${backups_dir}"/*; do
    [ -d "${schema_dir}" ] || continue

    # Discover unique basename-without-version keys via find + sed + sort -u.
    local basenames
    basenames="$(find "${schema_dir}" -maxdepth 1 -type f -name '*.bak.v*' -exec basename {} \; 2>/dev/null \
                  | sed -E 's/\.bak\.v[0-9]+$//' | sort -u)"
    [ -z "${basenames}" ] && continue

    local basename_key versions v
    while IFS= read -r basename_key; do
      [ -z "${basename_key}" ] && continue
      # Per-basename: list version numbers desc; drop top N; rm the rest.
      versions="$(find "${schema_dir}" -maxdepth 1 -type f -name "${basename_key}.bak.v*" \
                    -exec basename {} \; 2>/dev/null \
                  | sed -E "s/^.*\.bak\.v//" | sort -rn | tail -n +$(( keep + 1 )))"
      while IFS= read -r v; do
        [ -z "${v}" ] && continue
        rm -f "${schema_dir}/${basename_key}.bak.v${v}"
      done <<<"${versions}"
    done <<<"${basenames}"
  done
}
