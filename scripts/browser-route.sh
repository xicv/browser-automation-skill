#!/usr/bin/env bash
# scripts/browser-route.sh — register a network-route rule on the daemon.
# Usage: bash scripts/browser-route.sh [--site NAME] [--tool NAME]
#                                       [--dry-run] [--raw]
#                                       --pattern URL_PATTERN
#                                       --action allow|block|fulfill
#                                       [--status N]                    (fulfill)
#                                       [--body STR | --body-stdin]     (fulfill)
#
# Routes to chrome-devtools-mcp by default. Daemon-state-mutating: registers
# the rule in the daemon's routeRules array. Daemon-required.
#
# Phase 6 part 7-i: action ∈ {allow, block}.
# Phase 6 part 7-ii: action fulfill adds synthetic responses (--status / --body
# or --body-stdin). Body via stdin uses the same passthrough pattern as
# fill --secret-stdin (browser-fill.sh:87): the bash script forwards the
# --body-stdin flag and stdin inherits naturally to the bridge subprocess.
#
# Body binary-safety: any non-NUL byte sequence rides through. NUL itself
# can't ride bash variables or JSON strings — multipart bodies legitimately
# containing NUL would need a different transport (out of scope for 7-ii).

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

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

resolve_session_storage_state

pattern="" action="" status_code="" body_inline="" use_body_stdin=0
have_body_inline=0
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --pattern)
      pattern="${REMAINING_ARGV[i+1]:-}"
      [ -n "${pattern}" ] || die "${EXIT_USAGE_ERROR}" "--pattern requires a value"
      verb_argv+=(--pattern "${pattern}")
      i=$((i + 2))
      ;;
    --action)
      action="${REMAINING_ARGV[i+1]:-}"
      [ -n "${action}" ] || die "${EXIT_USAGE_ERROR}" "--action requires a value"
      case "${action}" in
        allow|block|fulfill) ;;
        *) die "${EXIT_USAGE_ERROR}" "--action must be one of {allow, block, fulfill} (got: ${action})" ;;
      esac
      verb_argv+=(--action "${action}")
      i=$((i + 2))
      ;;
    --status)
      status_code="${REMAINING_ARGV[i+1]:-}"
      [ -n "${status_code}" ] || die "${EXIT_USAGE_ERROR}" "--status requires a value"
      verb_argv+=(--status "${status_code}")
      i=$((i + 2))
      ;;
    --body)
      body_inline="${REMAINING_ARGV[i+1]:-}"
      have_body_inline=1
      verb_argv+=(--body "${body_inline}")
      i=$((i + 2))
      ;;
    --body-stdin)
      use_body_stdin=1
      verb_argv+=(--body-stdin)
      i=$((i + 1))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${pattern}" ] || die "${EXIT_USAGE_ERROR}" "route requires --pattern URL_PATTERN"
[ -n "${action}" ]  || die "${EXIT_USAGE_ERROR}" "route requires --action (allow|block|fulfill)"

# 7-ii validation: fulfill-only flags are rejected when paired with block/allow.
if [ "${action}" != "fulfill" ]; then
  [ -z "${status_code}" ] || die "${EXIT_USAGE_ERROR}" "--status is only valid with --action fulfill"
  [ "${have_body_inline}" = "0" ] || die "${EXIT_USAGE_ERROR}" "--body is only valid with --action fulfill"
  [ "${use_body_stdin}" = "0" ]   || die "${EXIT_USAGE_ERROR}" "--body-stdin is only valid with --action fulfill"
fi

# 7-ii: fulfill requires status + (body | body-stdin); body / body-stdin mutex.
body_bytes=0
if [ "${action}" = "fulfill" ]; then
  [ -n "${status_code}" ] || die "${EXIT_USAGE_ERROR}" "fulfill requires --status N (HTTP code in 100-599)"
  case "${status_code}" in
    ''|*[!0-9]*) die "${EXIT_USAGE_ERROR}" "--status must be an integer (got: ${status_code})" ;;
  esac
  if [ "${status_code}" -lt 100 ] || [ "${status_code}" -gt 599 ]; then
    die "${EXIT_USAGE_ERROR}" "--status must be in 100-599 (got: ${status_code})"
  fi
  if [ "${have_body_inline}" = "1" ] && [ "${use_body_stdin}" = "1" ]; then
    die "${EXIT_USAGE_ERROR}" "--body and --body-stdin are mutually exclusive"
  fi
  if [ "${have_body_inline}" = "0" ] && [ "${use_body_stdin}" = "0" ]; then
    die "${EXIT_USAGE_ERROR}" "fulfill requires --body STR or --body-stdin"
  fi
  if [ "${have_body_inline}" = "1" ]; then
    body_bytes="${#body_inline}"
  fi
  # body_bytes for --body-stdin is a daemon-side concern; bash doesn't peek at
  # stdin (would consume it before the bridge subprocess can read).
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  if [ "${action}" = "fulfill" ]; then
    ok "dry-run: would register fulfill rule pattern=${pattern} status=${status_code}"
    if [ "${use_body_stdin}" = "1" ]; then
      # Don't consume stdin in dry-run — body_bytes unknown until daemon reads it.
      emit_summary verb=route tool=none why=dry-run status=ok \
                   pattern="${pattern}" action="${action}" \
                   fulfill_status="${status_code}" body_source=stdin dry_run=true
    else
      emit_summary verb=route tool=none why=dry-run status=ok \
                   pattern="${pattern}" action="${action}" \
                   fulfill_status="${status_code}" body_bytes="${body_bytes}" dry_run=true
    fi
  else
    ok "dry-run: would register route rule pattern=${pattern} action=${action}"
    emit_summary verb=route tool=none why=dry-run status=ok \
                 pattern="${pattern}" action="${action}" dry_run=true
  fi
  exit 0
fi

picked="$(pick_tool route "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry route "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  if [ "${action}" = "fulfill" ]; then
    emit_summary verb=route tool="${tool_name}" why="${why}" status=ok \
                 pattern="${pattern}" action="${action}" \
                 fulfill_status="${status_code}"
  else
    emit_summary verb=route tool="${tool_name}" why="${why}" status=ok \
                 pattern="${pattern}" action="${action}"
  fi
  exit 0
fi
emit_summary verb=route tool="${tool_name}" why="${why}" status=error \
             pattern="${pattern}" action="${action}"
exit "${adapter_rc}"
