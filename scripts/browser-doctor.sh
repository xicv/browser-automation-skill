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
