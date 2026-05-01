#!/usr/bin/env bash
# tests/lint.sh — three-tier lint runner for the browser-skill repo.
# Tier 1 (static): file-content checks against scripts/lib/tool/*.sh
# Tier 2 (dynamic): subshell + JSON validation (see Task 11)
# Tier 3 (drift):  generated docs match generator output (see Task 13)
#
# Usage:
#   tests/lint.sh                # all tiers
#   tests/lint.sh --static-only  # tier 1 only (fast feedback)
#   tests/lint.sh --dynamic-only # tier 2 only
#   tests/lint.sh --drift-only   # tier 3 only

set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB_TOOL_DIR="${LIB_TOOL_DIR:-${REPO_ROOT}/scripts/lib/tool}"

REQUIRED_ADAPTER_FUNCTIONS=(
  tool_metadata tool_capabilities tool_doctor_check
  tool_open tool_click tool_fill tool_snapshot
  tool_inspect tool_audit tool_extract tool_eval
)

warn_lint() { printf 'lint: %s\n' "$*" >&2; }

lint_adapter_static() {
  local f="$1" name errors=0
  name="$(basename "${f}" .sh)"

  for fn in "${REQUIRED_ADAPTER_FUNCTIONS[@]}"; do
    if ! grep -qE "^(function +)?${fn}[[:space:]]*\(\)" "${f}"; then
      warn_lint "${f}: missing required function ${fn}"
      errors=$((errors + 1))
    fi
  done

  if grep -nE '^[[:space:]]*cd[[:space:]]' "${f}" >/dev/null 2>&1; then
    warn_lint "${f}: cd at file scope is forbidden (must be inside a tool_* function)"
    errors=$((errors + 1))
  fi

  awk '
    /^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ { in_fn=1 }
    /^\}/ { in_fn=0 }
    !in_fn && /^[[:space:]]*(curl|wget|nc)[[:space:]]/ { print NR": "$0 }
  ' "${f}" | while read -r leak; do
    [ -n "${leak}" ] && warn_lint "${f}: network call at file scope: ${leak}"
    errors=$((errors + 1))
  done

  if [ ! -f "${REPO_ROOT}/tests/${name}_adapter.bats" ]; then
    warn_lint "${f}: missing tests/${name}_adapter.bats"
    errors=$((errors + 1))
  fi

  local lines
  lines="$(wc -l < "${f}")"
  if [ "${lines}" -gt 500 ]; then
    warn_lint "${f}: file is ${lines} LOC, exceeds 500-LOC adapter cap"
    errors=$((errors + 1))
  fi

  return "${errors}"
}

run_static_tier() {
  local total_errors=0
  shopt -s nullglob
  for f in "${LIB_TOOL_DIR}"/*.sh; do
    [ "$(basename "${f}")" = ".gitkeep" ] && continue
    lint_adapter_static "${f}" || total_errors=$((total_errors + $?))
  done
  shopt -u nullglob
  return "${total_errors}"
}

lint_adapter_dynamic() {
  local f="$1" name errors=0
  name="$(basename "${f}" .sh)"

  local meta
  meta="$(
    # shellcheck source=/dev/null
    source "${f}" 2>/dev/null
    tool_metadata 2>/dev/null
  )" || { warn_lint "${f}: tool_metadata exited non-zero"; return 1; }

  if ! jq -e '.name and .abi_version and .version_pin and .cheatsheet_path' >/dev/null 2>&1 <<<"${meta}"; then
    warn_lint "${f}: tool_metadata missing required keys (name, abi_version, version_pin, cheatsheet_path)"
    errors=$((errors + 1))
  fi

  if [ "$(jq -r .name <<<"${meta}" 2>/dev/null)" != "${name}" ]; then
    warn_lint "${f}: tool_metadata.name doesn't match filename (\"${name}\")"
    errors=$((errors + 1))
  fi

  local declared_abi expected_abi
  declared_abi="$(jq -r .abi_version <<<"${meta}" 2>/dev/null)"
  expected_abi="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; printf '%s' \"\${BROWSER_SKILL_TOOL_ABI}\"")"
  if [ "${declared_abi}" != "${expected_abi}" ]; then
    warn_lint "${f}: abi_version mismatch (declared=${declared_abi}, framework=${expected_abi})"
    errors=$((errors + 1))
  fi

  local sheet
  sheet="$(jq -r .cheatsheet_path <<<"${meta}" 2>/dev/null)"
  if [ -n "${sheet}" ] && [ ! -f "${REPO_ROOT}/${sheet}" ]; then
    warn_lint "${f}: tool_metadata.cheatsheet_path '${sheet}' does not exist"
    errors=$((errors + 1))
  fi

  if ! (
    # shellcheck source=/dev/null
    source "${f}" 2>/dev/null
    tool_capabilities
  ) | jq -e . >/dev/null 2>&1; then
    warn_lint "${f}: tool_capabilities did not produce valid JSON"
    errors=$((errors + 1))
  fi

  if ! (
    # shellcheck source=/dev/null
    source "${f}" 2>/dev/null
    tool_doctor_check
  ) | jq -e . >/dev/null 2>&1; then
    warn_lint "${f}: tool_doctor_check did not produce valid JSON"
    errors=$((errors + 1))
  fi

  return "${errors}"
}

run_dynamic_tier() {
  local total_errors=0
  shopt -s nullglob
  for f in "${LIB_TOOL_DIR}"/*.sh; do
    [ "$(basename "${f}")" = ".gitkeep" ] && continue
    lint_adapter_dynamic "${f}" || total_errors=$((total_errors + $?))
  done
  shopt -u nullglob
  return "${total_errors}"
}

mode="all"
case "${1:-}" in
  --static-only)  mode="static" ;;
  --dynamic-only) mode="dynamic" ;;
  --drift-only)   mode="drift" ;;
  "")             mode="all" ;;
  *)              printf 'lint: unknown flag %s\n' "$1" >&2; exit 2 ;;
esac

errors=0
case "${mode}" in
  static)        run_static_tier   || errors=$((errors + $?)) ;;
  dynamic)       run_dynamic_tier  || errors=$((errors + $?)) ;;
  all)
    run_static_tier  || errors=$((errors + $?))
    run_dynamic_tier || errors=$((errors + $?))
    ;;
esac

exit "${errors}"
