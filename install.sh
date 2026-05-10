#!/usr/bin/env bash
# install.sh — preflight + state dir + symlink + (opt) git hooks. Idempotent.
set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

WITH_HOOKS=0
DRY_RUN=0
MODE=user   # phase-1 only supports --user; --project arrives in a later phase

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

  --user           (default) symlink to ~/.claude/skills/, state at ~/.browser-skill/
  --with-hooks     enable .githooks/pre-commit credential-leak blocker
  --dry-run        print what would happen, change nothing
  -h, --help       this message
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --user)        MODE=user ;;
    --with-hooks)  WITH_HOOKS=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             warn "ignoring unknown arg: ${arg}" ;;
  esac
done

preflight() {
  command -v jq >/dev/null 2>&1 || die "${EXIT_PREFLIGHT_FAILED}" "jq required but not found. Remediation: brew install jq (macOS) or apt install jq (Debian)"
  ok "jq found: $(command -v jq)"
  command -v python3 >/dev/null 2>&1 || die "${EXIT_PREFLIGHT_FAILED}" "python3 required but not found"
  ok "python3 found: $(command -v python3)"
  local major="${BASH_VERSINFO[0]:-0}"
  [ "${major}" -ge 4 ] || die "${EXIT_PREFLIGHT_FAILED}" "bash >= 4 required (have ${BASH_VERSION}). Remediation: brew install bash"
  ok "bash version: ${BASH_VERSION}"
}

ok "browser-automation-skill installer (mode=${MODE} dry-run=${DRY_RUN})"
preflight

if [ "${DRY_RUN}" = "1" ]; then
  init_paths
  ok "dry-run: would create ${BROWSER_SKILL_HOME} and symlink to ${HOME}/.claude/skills/browser-automation-skill"
  exit 0
fi

init_paths

create_state_dir() {
  mkdir -p \
    "${BROWSER_SKILL_HOME}" \
    "${SITES_DIR}" \
    "${SESSIONS_DIR}" \
    "${CREDENTIALS_DIR}" \
    "${CAPTURES_DIR}" \
    "${FLOWS_DIR}"
  chmod 700 \
    "${BROWSER_SKILL_HOME}" \
    "${SITES_DIR}" \
    "${SESSIONS_DIR}" \
    "${CREDENTIALS_DIR}" \
    "${CAPTURES_DIR}" \
    "${FLOWS_DIR}"
  # Defense in depth: if this dir ever ends up inside a git repo, ignore it.
  printf '*\n' > "${BROWSER_SKILL_HOME}/.gitignore"
  # Schema version marker.
  printf '1\n' > "${BROWSER_SKILL_HOME}/version"
  # Phase 7 part 1-v: default capture-retention config. Idempotent — never
  # overwrite an existing user-edited config. Defaults per parent spec §4.5.
  if [ ! -f "${CONFIG_FILE}" ]; then
    cat > "${CONFIG_FILE}" <<'EOF'
{
  "schema_version": 1,
  "retention_days": 14,
  "retention_count": 500,
  "warn_at_pct": 90
}
EOF
    chmod 600 "${CONFIG_FILE}"
  fi
  ok "state dir ready: ${BROWSER_SKILL_HOME}"
}

create_state_dir

install_symlink() {
  local skills_dir="${HOME}/.claude/skills"
  local link="${skills_dir}/browser-automation-skill"
  mkdir -p "${skills_dir}"

  if [ -L "${link}" ]; then
    ln -sfn "${REPO_ROOT}" "${link}"
    ok "updated existing symlink: ${link} -> ${REPO_ROOT}"
  elif [ -e "${link}" ]; then
    die "${EXIT_PREFLIGHT_FAILED}" "${link} exists and is not a symlink; refusing to overwrite. Move it aside and re-run."
  else
    ln -s "${REPO_ROOT}" "${link}"
    ok "created symlink: ${link} -> ${REPO_ROOT}"
  fi
}

install_symlink

if [ "${WITH_HOOKS}" = "1" ]; then
  bash "${REPO_ROOT}/scripts/install-git-hooks.sh"
fi

ok "running doctor..."
doctor_rc=0
doctor_out="$(bash "${REPO_ROOT}/scripts/browser-doctor.sh" 2>&1)" || doctor_rc=$?
printf '%s\n' "${doctor_out}"

# Count adapters_ok from the doctor JSON summary line (last line).
adapters_ok="$(printf '%s\n' "${doctor_out}" | tail -1 | jq -r '.adapters_ok // 0' 2>/dev/null || printf '0')"

ok "install complete; next steps:"
ok "  1. /browser doctor       (verify in Claude Code)"
ok "  2. /browser add-site --name NAME --url URL    (register your first site)"
ok "  3. /browser use --set NAME    (set as current)"

if [ "${doctor_rc}" -ne 0 ]; then
  warn "doctor reported issues (exit ${doctor_rc}); run 'bash scripts/browser-doctor.sh' to review"
fi

# v1-polish: when no adapters installed, surface the install-adapter guidance
# explicitly so first-time users don't have to decode the doctor JSON.
if [ "${adapters_ok}" = "0" ] || [ -z "${adapters_ok}" ]; then
  warn ""
  warn "no browser adapters installed. install at least one to drive a real browser:"
  warn "  - chrome-devtools-mcp  (recommended; most-complete):  npx -y chrome-devtools-mcp@latest"
  warn "  - playwright-cli       (npm; supports headless+headed): npm i -g playwright @playwright/test @playwright/cli && playwright install chromium"
  warn "  - obscura              (single-binary; scrape+stealth-only): https://github.com/h4ckf0r0day/obscura/releases"
  warn ""
  warn "without an adapter: site/session/credential management + cache record + propose work; navigation/interaction/capture verbs return EXIT_TOOL_MISSING (21)."
fi
