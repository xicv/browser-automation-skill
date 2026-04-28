#!/usr/bin/env bash
# browser-doctor — health check, exits non-zero on issues. Zero network calls.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
init_paths

# BSD date (macOS) does not support %3N; use python3 as portable fallback.
_ms_now() {
  local t
  t="$(date +%s%3N 2>/dev/null)"
  # If the result ends with 'N' then %3N is unsupported — fall back to python3.
  case "${t}" in
    *N) python3 -c 'import time; print(int(time.time()*1000))' ;;
    *)  printf '%s\n' "${t}" ;;
  esac
}
started_at_ms="$(_ms_now)"
problems=0

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
  mode="$(stat -f '%Lp' "${BROWSER_SKILL_HOME}" 2>/dev/null || stat -c '%a' "${BROWSER_SKILL_HOME}" 2>/dev/null || echo "?")"
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
check_cmd node "(optional in phase 1) brew install node (>=20)"

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

duration_ms=$(( $(_ms_now) - started_at_ms ))

if [ "${problems}" -eq 0 ]; then
  ok "all checks passed"
  summary_json verb=doctor tool=none why=health-check status=ok problems=0 duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
else
  warn "${problems} problem(s) found"
  summary_json verb=doctor tool=none why=health-check status=error problems="${problems}" duration_ms="${duration_ms}"
  exit "${EXIT_PREFLIGHT_FAILED}"
fi
