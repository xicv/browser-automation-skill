#!/usr/bin/env bash
# scripts/browser-upload.sh — fill <input type=file> by --ref + --path.
# Usage: bash scripts/browser-upload.sh [--site NAME] [--tool NAME] [--dry-run]
#                                        [--raw] --ref eN --path PATH
#                                        [--allow-sensitive]
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 6). Stateful —
# requires running daemon (refMap precondition).
#
# SECURITY (path validation, performed bash-side BEFORE invoking adapter):
#   1. Path must exist and be a regular file (not dir, not device, not symlink-to-elsewhere).
#   2. Path must be readable by the current user.
#   3. Path must NOT match common sensitive patterns (~/.ssh/*, ~/.aws/*,
#      ~/.config/*credentials*, *.env). Override via --allow-sensitive
#      (typed acknowledgment that the agent is uploading sensitive material
#      intentionally — covers legit use cases like "upload my GPG key").
# Path is then resolved (`readlink -f` / `realpath`) and forwarded to MCP.

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

ref="" path="" allow_sensitive=0
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --ref)
      ref="${REMAINING_ARGV[i+1]:-}"
      [ -n "${ref}" ] || die "${EXIT_USAGE_ERROR}" "--ref requires a value"
      verb_argv+=(--ref "${ref}")
      i=$((i + 2))
      ;;
    --path)
      path="${REMAINING_ARGV[i+1]:-}"
      [ -n "${path}" ] || die "${EXIT_USAGE_ERROR}" "--path requires a value"
      i=$((i + 2))
      ;;
    --allow-sensitive)
      allow_sensitive=1
      i=$((i + 1))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${ref}" ]  || die "${EXIT_USAGE_ERROR}" "upload requires --ref eN"
[ -n "${path}" ] || die "${EXIT_USAGE_ERROR}" "upload requires --path PATH"

# Path security validation (bash-side, before adapter dispatch).
# 1. File must exist + be a regular file.
if [ ! -e "${path}" ]; then
  die "${EXIT_USAGE_ERROR}" "upload: path does not exist: ${path}"
fi
if [ ! -f "${path}" ]; then
  die "${EXIT_USAGE_ERROR}" "upload: path is not a regular file (directory, device, or other): ${path}"
fi
# 2. File must be readable.
if [ ! -r "${path}" ]; then
  die "${EXIT_USAGE_ERROR}" "upload: path is not readable by the current user: ${path}"
fi
# 3. Sensitive-pattern reject. Common locations agents shouldn't accidentally
#    upload from. Override with --allow-sensitive when intentional.
if [ "${allow_sensitive}" -ne 1 ]; then
  case "${path}" in
    *.ssh/*|*/.ssh/*|*.aws/credentials|*/.aws/credentials|*/.env|*.env|\
    */credentials|*/credentials.json|*/secrets.json|*/private_key*|*/id_rsa*|\
    */id_ed25519*|*/id_ecdsa*)
      die "${EXIT_USAGE_ERROR}" "upload: path '${path}' matches a sensitive pattern (SSH key / AWS / .env / private_key); pass --allow-sensitive to override"
      ;;
  esac
fi

# Resolve to canonical path (eliminate symlink shenanigans). Cross-platform:
# `readlink -f` is GNU; macOS BSD has it via Xcode 11+ but `realpath` is more
# portable. Try realpath first, fall back to readlink -f.
canonical_path="$(realpath "${path}" 2>/dev/null || readlink -f "${path}" 2>/dev/null || printf '%s' "${path}")"

verb_argv+=(--path "${canonical_path}")

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would upload ${canonical_path} to ${ref}"
  emit_summary verb=upload tool=none why=dry-run status=ok \
               ref="${ref}" path="${canonical_path}" dry_run=true
  exit 0
fi

picked="$(pick_tool upload "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry upload "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=upload tool="${tool_name}" why="${why}" status=ok \
               ref="${ref}" path="${canonical_path}"
  exit 0
fi
emit_summary verb=upload tool="${tool_name}" why="${why}" status=error \
             ref="${ref}" path="${canonical_path}"
exit "${adapter_rc}"
