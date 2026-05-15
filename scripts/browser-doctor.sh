#!/usr/bin/env bash
# browser-doctor — health check, exits non-zero on issues. Zero network calls.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
init_paths

started_at_ms="$(now_ms)"
problems=0

# Required check: increments problems on miss. Doctor will exit non-zero.
check_cmd() {
  local cmd="$1" hint="$2"
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "${cmd} found: $(command -v "${cmd}")"
  else
    warn "${cmd} NOT FOUND"
    warn "  remediation: ${hint}"
    problems=$((problems + 1))
  fi
}

# Advisory check: prints status but does NOT increment problems. Use for tools
# that are required by later phases but optional in the current phase, OR for
# tools that the user will install when they actually need them.
check_cmd_advisory() {
  local cmd="$1" hint="$2"
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "${cmd} found: $(command -v "${cmd}")"
  else
    warn "${cmd} NOT FOUND (advisory only — does not fail doctor)"
    warn "  remediation: ${hint}"
  fi
}

check_bash_version() {
  local major="${BASH_VERSINFO[0]:-0}"
  if [ "${major}" -ge 4 ]; then
    ok "bash version: ${BASH_VERSION}"
  else
    warn "bash ${BASH_VERSION} is too old (need >= 4)"
    warn "  remediation: brew install bash"
    problems=$((problems + 1))
  fi
}

check_home() {
  if [ ! -d "${BROWSER_SKILL_HOME}" ]; then
    warn "${BROWSER_SKILL_HOME} does not exist"
    warn "  remediation: run ./install.sh from the repo root"
    problems=$((problems + 1))
    return 0
  fi
  local mode
  mode="$(file_mode "${BROWSER_SKILL_HOME}")"
  [ -n "${mode}" ] || mode="?"
  if [ "${mode}" != "700" ]; then
    warn "${BROWSER_SKILL_HOME} has mode ${mode}, expected 700"
    warn "  remediation: chmod 700 ${BROWSER_SKILL_HOME}"
    problems=$((problems + 1))
  else
    ok "${BROWSER_SKILL_HOME} mode 700"
  fi
}

ok "browser-skill home: ${BROWSER_SKILL_HOME}"
ok "browser-skill doctor"

check_cmd jq "brew install jq (macOS) or apt install jq (Debian)"
check_cmd python3 "brew install python3 (macOS) or apt install python3"
check_bash_version
check_home
# Tools below are recommended but not required in Phase 1; later phases will
# elevate these to required and add version-pinning logic.
check_cmd node "brew install node (>=20) — required by playwright-cli adapter; was advisory in Phase 1-2"

check_disk_encryption() {
  case "$(uname -s)" in
    Darwin)
      if command -v fdesetup >/dev/null 2>&1; then
        local status
        status="$(fdesetup status 2>/dev/null || true)"
        case "${status}" in
          *"FileVault is On"*)  ok "disk encryption: FileVault on" ;;
          *"FileVault is Off"*) warn "disk encryption: FileVault OFF (advisory — 0600 modes are paper without disk encryption)" ;;
          *)                    warn "disk encryption: status unknown (fdesetup said: ${status:-empty})" ;;
        esac
      else
        warn "disk encryption: fdesetup not found (cannot verify)"
      fi
      ;;
    Linux)
      if command -v lsblk >/dev/null 2>&1 && lsblk -o NAME,FSTYPE 2>/dev/null | grep -q crypto_LUKS; then
        ok "disk encryption: LUKS-backed volume detected"
      else
        warn "disk encryption: no LUKS volume found (advisory)"
      fi
      ;;
    *)
      warn "disk encryption: unknown OS — please verify manually"
      ;;
  esac
}

check_disk_encryption

# --- Adapter aggregation (extension model §5.2) ---
# Walk lib/tool/*.sh in subshells; collect each adapter's tool_doctor_check.
# Subshell isolation prevents tool_open / tool_click / etc. from colliding.
adapters_ok=0
adapters_failed=0
adapter_files=("${LIB_TOOL_DIR}"/*.sh)

if [ ! -f "${adapter_files[0]}" ]; then
  warn "no adapters found under ${LIB_TOOL_DIR}"
else
  for adapter_file in "${adapter_files[@]}"; do
    adapter_name="$(basename "${adapter_file}" .sh)"
    result="$(
      # shellcheck source=/dev/null
      source "${adapter_file}" 2>/dev/null
      tool_doctor_check 2>/dev/null
    )" || result='{"ok":false,"error":"adapter source failed"}'

    jq -c --arg n "${adapter_name}" '. + {check:"adapter",adapter:$n}' <<<"${result}"

    if [ "$(printf '%s' "${result}" | jq -r .ok 2>/dev/null)" = "true" ]; then
      adapters_ok=$((adapters_ok + 1))
      ok "adapter ${adapter_name}: ok"
    else
      adapters_failed=$((adapters_failed + 1))
      warn "adapter ${adapter_name}: $(printf '%s' "${result}" | jq -r '.error // "failed"')"
    fi
  done
fi

# --- Credentials count (advisory; never fails doctor) ---
# Phase 5 part 2d: walk ${CREDENTIALS_DIR}/*.json and report per-backend.
# .secret files are payload, not metadata, so they're skipped.
creds_total=0
creds_keychain=0
creds_libsecret=0
creds_plaintext=0
if [ -d "${CREDENTIALS_DIR}" ]; then
  shopt -s nullglob
  for cred_file in "${CREDENTIALS_DIR}"/*.json; do
    creds_total=$((creds_total + 1))
    backend="$(jq -r .backend "${cred_file}" 2>/dev/null || printf 'unknown')"
    case "${backend}" in
      keychain)  creds_keychain=$((creds_keychain + 1)) ;;
      libsecret) creds_libsecret=$((creds_libsecret + 1)) ;;
      plaintext) creds_plaintext=$((creds_plaintext + 1)) ;;
    esac
  done
  shopt -u nullglob
fi
ok "credentials: ${creds_total} total (keychain: ${creds_keychain}, libsecret: ${creds_libsecret}, plaintext: ${creds_plaintext})"

# --- Captures sanitization counter (advisory; never fails doctor) ---
# Phase 7 part 1-iv: walk ${CAPTURES_DIR}/*/meta.json and count total +
# sanitized:false. Missing/null .sanitized treated as sanitized=true
# (forward-compat with pre-7-1-iv captures).
captures_total=0
captures_unsanitized=0
captures_unsanitized_ids=""
if [ -d "${CAPTURES_DIR}" ]; then
  shopt -s nullglob
  for capture_meta in "${CAPTURES_DIR}"/*/meta.json; do
    captures_total=$((captures_total + 1))
    # Note: don't use `// true` — jq's `//` fires on null OR false, so a
    # legit sanitized=false would resolve to "true". Read raw; missing field
    # surfaces as "null" which is correctly NOT-equal-to-"false" below.
    sanitized="$(jq -r '.sanitized' "${capture_meta}" 2>/dev/null || printf 'null')"
    if [ "${sanitized}" = "false" ]; then
      captures_unsanitized=$((captures_unsanitized + 1))
      capture_id="$(jq -r '.capture_id // "?"' "${capture_meta}" 2>/dev/null || printf '?')"
      captures_unsanitized_ids="${captures_unsanitized_ids:+${captures_unsanitized_ids}, }captures/${capture_id}/"
    fi
  done
  shopt -u nullglob
fi
ok "captures: ${captures_total} total (sanitized:false: ${captures_unsanitized})"
if [ "${captures_unsanitized}" -gt 0 ]; then
  warn "${captures_unsanitized} capture(s) with sanitization disabled — review ${captures_unsanitized_ids}"
fi

# --- Pending migrations (advisory; never fails doctor) ---
# Phase 10 follow-up. Sources lib/migrate.sh and calls migrate_check, which is
# read-only by design (no lock acquired; MIG4 invariant from the Phase 10
# design doc — "doctor never auto-migrates"). Doctor surfaces pending count
# only; user invokes `browser-migrate run` to apply them.
# shellcheck source=lib/migrate.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/migrate.sh"
migrations_pending=0
# migrate_check emits one _kind:migration_needed line per pending migrator,
# then a summary line. Count the _kind events; ignore the summary.
mig_out="$(migrate_check 2>/dev/null || true)"
if [ -n "${mig_out}" ]; then
  migrations_pending="$(printf '%s\n' "${mig_out}" \
    | jq -s 'map(select(._kind == "migration_needed")) | length' 2>/dev/null \
    || printf '0')"
fi
jq -nc --argjson n "${migrations_pending}" '{check:"migrations", pending:$n}'
if [ "${migrations_pending}" -gt 0 ]; then
  warn "${migrations_pending} pending migration(s) — run 'browser-migrate check' for details (advisory; never fails doctor)"
else
  ok "no pending migrations"
fi

# --- Memory cache hit-rate (advisory; forward-compat read side) ---
# Phase 11 v2 will tee `verb=do mode=intent` summary lines into
# ${BROWSER_SKILL_HOME}/memory/events.jsonl. Doctor's read side ships now;
# absent file → "n/a" line. Lifetime ratio over all events (no time filter
# until events carry timestamps).
cache_events_log="${BROWSER_SKILL_HOME}/memory/events.jsonl"
if [ -f "${cache_events_log}" ]; then
  # Phase 12 part 2 audit: single jq pass extracts both counts (one file
  # read, one fork) instead of two sequential `jq -s` slurps.
  cache_pair="$(jq -s -r '
    [(map(select(.cache_hit == true or .cache_hit == false)) | length),
     (map(select(.cache_hit == true)) | length)] | @tsv
  ' "${cache_events_log}" 2>/dev/null || printf '0\t0')"
  IFS=$'\t' read -r cache_total cache_hits <<<"${cache_pair}"
  cache_total="${cache_total:-0}"
  cache_hits="${cache_hits:-0}"
  if [ "${cache_total}" -gt 0 ]; then
    # Integer-only math; bc not available everywhere and shellcheck dislikes pipe-to-bc.
    cache_rate_pct=$(( cache_hits * 100 / cache_total ))
    ok "memory cache hit rate: ${cache_rate_pct}% (${cache_hits}/${cache_total} events)"
    jq -nc \
      --argjson hits "${cache_hits}" \
      --argjson total "${cache_total}" \
      --argjson pct "${cache_rate_pct}" \
      '{check:"memory_cache", hits:$hits, total:$total, hit_rate_pct:$pct}'
  else
    ok "memory cache hit rate: n/a (events log present but empty)"
    jq -nc '{check:"memory_cache", hits:0, total:0, hit_rate_pct:null}'
  fi
else
  ok "memory cache hit rate: n/a (no events yet — run 'browser-do --intent' to generate cache observations)"
  jq -nc '{check:"memory_cache", hits:0, total:0, hit_rate_pct:null}'
fi

# --- Tier 3: recent_urls.jsonl line count (advisory; forward-compat read side) ---
# Parallel to memory_cache check above. Phase 11 v2 Pick A6 (PR #125) added
# the writer; doctor reports the line count so users see passive observation
# is actually accumulating. Absent log → 0 entries (not an error).
recent_urls_log="${BROWSER_SKILL_HOME}/memory/recent_urls.jsonl"
if [ -f "${recent_urls_log}" ]; then
  recent_urls_count="$(jq -s 'length' "${recent_urls_log}" 2>/dev/null || printf '0')"
  ok "recent_urls: ${recent_urls_count} entries (passive navigation log)"
else
  recent_urls_count=0
  ok "recent_urls: 0 entries (no navigations yet — run 'browser-open --site SITE --url URL' to populate)"
fi
jq -nc --argjson n "${recent_urls_count}" '{check:"recent_urls", count:$n}'

# --- Tier 3: stats.jsonl — per-action telemetry health (Phase 12 part 1) ---
# Parallel to memory_cache + recent_urls checks. Reports event count, success
# rate over the last 7 days, and an oblivious_success warning when > 0. Absent
# log → 0 entries (not an error). Doctor never rebuilds the SQLite mirror —
# that's `browser-stats rebuild`'s job.
stats_jsonl_log="${BROWSER_SKILL_HOME}/memory/stats.jsonl"
if [ -f "${stats_jsonl_log}" ]; then
  # Phase 12 part 2 audit: single jq pass extracts {total, success, oblivious}
  # in one file read + one fork. Replaces 3× sequential `jq -s` slurps.
  stats_triple="$(jq -s -r '
    [length,
     (map(select(.outcome == "success")) | length),
     (map(select(.failure_mode == "oblivious_success")) | length)] | @tsv
  ' "${stats_jsonl_log}" 2>/dev/null || printf '0\t0\t0')"
  IFS=$'\t' read -r stats_total stats_success stats_oblivious <<<"${stats_triple}"
  stats_total="${stats_total:-0}"
  stats_success="${stats_success:-0}"
  stats_oblivious="${stats_oblivious:-0}"
  if [ "${stats_total}" -gt 0 ]; then
    stats_success_pct=$(( stats_success * 100 / stats_total ))
    ok "stats events: ${stats_total} (${stats_success_pct}% success)"
  else
    ok "stats events: 0 (log present but empty)"
    stats_success_pct=0
  fi
  if [ "${stats_oblivious}" -gt 0 ]; then
    warn "${stats_oblivious} oblivious_success event(s) — adapter reported ok but post-condition failed; run 'browser-stats report'"
  fi
  jq -nc \
    --argjson total "${stats_total}" \
    --argjson success "${stats_success}" \
    --argjson oblivious "${stats_oblivious}" \
    --argjson pct "${stats_success_pct:-0}" \
    '{check:"stats", total:$total, success:$success, success_pct:$pct, oblivious_success:$oblivious}'
else
  ok "stats events: 0 (no telemetry yet — emitted automatically by open/click/fill/snapshot/extract)"
  jq -nc '{check:"stats", total:0, success:0, success_pct:null, oblivious_success:0}'
fi

duration_ms=$(( $(now_ms) - started_at_ms ))

# Status semantics (§5.3 of extension-model spec).
if [ "${problems}" -gt 0 ]; then
  overall_status="error"
  exit_code="${EXIT_PREFLIGHT_FAILED}"
elif [ "${adapters_ok}" -eq 0 ] && [ "${adapters_failed}" -gt 0 ]; then
  overall_status="error"
  exit_code="${EXIT_PREFLIGHT_FAILED}"
elif [ "${adapters_failed}" -gt 0 ]; then
  overall_status="partial"
  exit_code="${EXIT_OK}"
else
  overall_status="ok"
  exit_code="${EXIT_OK}"
fi

if [ "${overall_status}" = "ok" ]; then
  ok "all checks passed (${adapters_ok} adapter(s) ok)"
else
  warn "${problems} core problem(s); ${adapters_ok} adapter(s) ok, ${adapters_failed} failed"
fi

summary_json verb=doctor tool=none why=health-check status="${overall_status}" \
  problems="${problems}" \
  adapters_ok="${adapters_ok}" adapters_failed="${adapters_failed}" \
  duration_ms="${duration_ms}"
exit "${exit_code}"
