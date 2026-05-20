#!/usr/bin/env bash
# scripts/browser-open.sh — open a URL via the routed adapter.
# Usage: bash scripts/browser-open.sh [--site NAME] [--tool NAME] [--dry-run]
#                                     [--raw] --url <URL>
# Emits one streaming JSON line per adapter event (if any), then a single
# JSON summary line. See docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md §5.4
# and docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md §3.

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
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
# shellcheck source=lib/memory.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/memory.sh"
# shellcheck source=lib/stats.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/stats.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

# Resolve site/session → BROWSER_SKILL_STORAGE_STATE (no-op if neither set).
# Router's rule_session_required reads the env var to prefer playwright-lib.
resolve_session_storage_state

url=""
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --url)
      url="${REMAINING_ARGV[i+1]:-}"
      [ -n "${url}" ] || die "${EXIT_USAGE_ERROR}" "--url requires a value"
      verb_argv+=(--url "${url}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${url}" ] || die "${EXIT_USAGE_ERROR}" "--url <URL> is required"

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would open ${url}"
  emit_summary verb=open tool=none why=dry-run status=ok url="${url}" dry_run=true
  exit 0
fi

picked="$(pick_tool open "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

stats_t0="$(now_ms)"
set +e
adapter_out="$(invoke_with_retry open "${verb_argv[@]}")"
adapter_rc=$?
set -e

# Phase 12 part 1 + Phase 14 (Bundle #2): per-action telemetry with auto-derived
# post-condition. The adapter's stdout for `open` typically echoes the navigated
# URL (e.g. `{"event":"navigate","url":"…","status":200}`); using that as
# OBSERVED lets us detect redirect-to-login / app-router rewrites that current
# self-reported success would silently miss (the cheatsheet's killer
# "oblivious_success" signal). Caller-set env wins via `:=` parameter expansion.
if [ "${adapter_rc}" -eq 0 ] && [ -n "${adapter_out}" ]; then
  : "${BROWSER_STATS_EXPECT_TYPE:=url}"
  : "${BROWSER_STATS_EXPECT_MATCH:=include}"
  : "${BROWSER_STATS_EXPECT_VALUE:=${url}}"
  : "${BROWSER_STATS_OBSERVED:=${adapter_out}}"
else
  : "${BROWSER_STATS_OBSERVED:=${url}}"
fi
export BROWSER_STATS_EXPECT_TYPE BROWSER_STATS_EXPECT_MATCH BROWSER_STATS_EXPECT_VALUE BROWSER_STATS_OBSERVED

stats_run_adapter_emit \
  "open" "${tool_name}" "${stats_t0}" "${adapter_rc}" "${adapter_out}" "" \
  -- "${verb_argv[@]}" || true

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  # Pick A6: passive observation. Best-effort tee to recent_urls.jsonl when a
  # site is in scope. --site flag (ARG_SITE from parse_verb_globals) wins;
  # falls back to current_get (sticky current site). Site-less navigations
  # skip the tee — recent_urls is site-scoped for `propose --from-recent`.
  # Failure emits warn: in the helper and continues; never taints exit code.
  _open_site="${ARG_SITE:-$(current_get 2>/dev/null || true)}"
  if [ -n "${_open_site}" ]; then
    memory_record_recent_url "${_open_site}" "${url}" "open" 2>/dev/null || true
    # Phase 14 B1: opportunistic URL-pattern clustering. Now that recent_urls
    # has a fresh entry, ask browser-do propose to (a) cluster recent URLs by
    # templated path, (b) emit patterns that meet threshold ≥3, (c) write
    # any new patterns to memory/<site>/patterns.json. Compounds zero-token
    # clicks for repeat actions — the `browser-do` cache engine has been
    # shipped since Phase 11 but was idle because nothing triggered propose.
    # Gated by env so existing flows that don't want this overhead can opt out:
    #   BROWSER_SKILL_OPEN_PROPOSE=0  → skip (default: 1 / on)
    # Cost: ~50ms (jq + node url-pattern-cluster.mjs). Best-effort: failure
    # emits its own warn in browser-do; never taints open's exit code.
    if [ "${BROWSER_SKILL_OPEN_PROPOSE:-1}" = "1" ]; then
      bash "${SCRIPT_DIR}/browser-do.sh" propose \
        --site "${_open_site}" --from-recent --auto-record --threshold 3 \
        >/dev/null 2>&1 || true
    fi
  fi
  emit_summary verb=open tool="${tool_name}" why="${why}" status=ok url="${url}"
  exit 0
fi
emit_summary verb=open tool="${tool_name}" why="${why}" status=error url="${url}"
exit "${adapter_rc}"
