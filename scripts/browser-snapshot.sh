#!/usr/bin/env bash
# scripts/browser-snapshot.sh — capture an accessibility snapshot via the
# routed adapter; result is eN-indexed per token-efficient-output spec §5.
# Usage: bash scripts/browser-snapshot.sh [--site NAME] [--tool NAME]
#                                         [--dry-run] [--raw] [--depth N]
#                                         [--capture]
#
# Phase 7 part 1-i: --capture writes adapter stdout to
# ${CAPTURES_DIR}/NNN/snapshot.json + meta.json. capture_id joins the summary.
# Snapshot is structurally safe (refs only, no headers/cookies) — sanitization
# arrives in 7-iii when console.json + network.har enter the picture.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/router.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/router.sh"
# shellcheck source=lib/verb_helpers.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/verb_helpers.sh"
# shellcheck source=lib/capture.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/capture.sh"
# shellcheck source=lib/stats.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/stats.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

# Resolve site/session → BROWSER_SKILL_STORAGE_STATE (no-op if neither set).
# Router's rule_session_required reads the env var to prefer playwright-lib.
resolve_session_storage_state

# Strip --capture (verb-script-level; not for adapter dispatch). All other
# args pass through.
do_capture=0
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --capture)
      do_capture=1
      i=$((i + 1))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would snapshot"
  if [ "${do_capture}" = "1" ]; then
    emit_summary verb=snapshot tool=none why=dry-run status=ok dry_run=true capture=true
  else
    emit_summary verb=snapshot tool=none why=dry-run status=ok dry_run=true
  fi
  exit 0
fi

picked="$(pick_tool snapshot "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

# Open capture dir BEFORE adapter call so meta.json/in_progress lands even if
# the adapter crashes before producing output.
if [ "${do_capture}" = "1" ]; then
  capture_start snapshot
fi

# invoke_with_retry wraps tool_snapshot in transparent retry-on-EXIT_SESSION_
# EXPIRED (phase-5 part 3-ii).
stats_t0="$(now_ms)"
set +e
adapter_out="$(invoke_with_retry snapshot "${verb_argv[@]}")"
adapter_rc=$?
set -e

# Phase 14 (Bundle #1): heavy snapshots → file ref per spec §3.2 ("refs_inline
# only when total length ≤ 2 KB. Above that threshold, fall back to
# snapshot_path"). Real telemetry (35 events) showed avg 1570B / max 4567B
# snapshot output — borderline-to-bloat. File-ref cuts repeat-snapshot cost on
# the same page from re-paying-the-tokens to one-Read-then-cache.
# Overrides:
#   BROWSER_SKILL_SNAPSHOT_INLINE_BYTES  threshold (default 2048)
#   BROWSER_SKILL_SNAPSHOT_TEASER_BYTES  truncated-body cap when over (default 512)
snapshot_threshold="${BROWSER_SKILL_SNAPSHOT_INLINE_BYTES:-2048}"
teaser_cap="${BROWSER_SKILL_SNAPSHOT_TEASER_BYTES:-512}"
snapshot_path=""
n_refs=0
adapter_out_bytes=${#adapter_out}
if [ "${adapter_rc}" -eq 0 ] \
   && [ "${adapter_out_bytes}" -gt "${snapshot_threshold}" ]; then
  snapshot_site="${ARG_SITE:-anon}"
  if snapshot_path="$(capture_path snapshots "${snapshot_site}" yaml 2>/dev/null)"; then
    if printf '%s' "${adapter_out}" > "${snapshot_path}" 2>/dev/null; then
      chmod 600 "${snapshot_path}" 2>/dev/null || true
      n_refs="$(printf '%s' "${adapter_out}" \
                | grep -oE '\[ref=e[0-9]+\]' | wc -l | tr -d ' ')"
      teaser_head="$(printf '%s' "${adapter_out}" | head -c "${teaser_cap}")"
      adapter_out="${teaser_head}
... (truncated; full snapshot at ${snapshot_path}; ${n_refs} refs)"
    else
      # File write failed — revert to inline so we never lose the snapshot.
      warn "snapshot: failed to write ${snapshot_path}; falling back to inline"
      snapshot_path=""
    fi
  else
    warn "snapshot: capture_path rejected site='${snapshot_site}'; inline fallback"
    snapshot_path=""
  fi
fi

# Phase 12 part 1: per-action telemetry. Snapshots have no natural post-cond
# observed value beyond the snapshot body; observed=adapter_out supports
# element_value matchers (rare but supported). After Phase 14, adapter_out is
# already the teaser when redirected — telemetry naturally records the
# compressed payload (no second jsonl bloat).
BROWSER_STATS_OBSERVED="${adapter_out}" \
  stats_run_adapter_emit \
    "snapshot" "${tool_name}" "${stats_t0}" "${adapter_rc}" "${adapter_out}" "" \
    -- "${verb_argv[@]}" || true

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

# Persist adapter stdout to snapshot.json before finalizing meta.json (so the
# inventory + total_bytes reflect the artifact). When snapshot_path was set
# above, write the FULL body (from the file we already created) so --capture
# still gets the unredacted YAML.
if [ "${do_capture}" = "1" ]; then
  if [ -n "${snapshot_path}" ] && [ -f "${snapshot_path}" ]; then
    cp "${snapshot_path}" "${CAPTURE_DIR}/snapshot.json"
    chmod 600 "${CAPTURE_DIR}/snapshot.json"
  elif [ -n "${adapter_out}" ]; then
    printf '%s\n' "${adapter_out}" > "${CAPTURE_DIR}/snapshot.json"
    chmod 600 "${CAPTURE_DIR}/snapshot.json"
  fi
  if [ "${adapter_rc}" -eq 0 ]; then
    capture_finish ok
  else
    capture_finish error
  fi
fi

# Build summary kv list (snapshot_path + n_refs only when redirected).
summary_extra=()
if [ -n "${snapshot_path}" ]; then
  summary_extra+=("snapshot_path=${snapshot_path}" "n_refs=${n_refs}")
fi
if [ "${do_capture}" = "1" ]; then
  summary_extra+=("capture_id=${CAPTURE_ID}")
fi

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=snapshot tool="${tool_name}" why="${why}" status=ok \
    "${summary_extra[@]}"
  exit 0
fi
emit_summary verb=snapshot tool="${tool_name}" why="${why}" status=error \
  "${summary_extra[@]}"
exit "${adapter_rc}"
