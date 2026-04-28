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
  ok "dry-run: would create ~/.browser-skill/ and symlink to ~/.claude/skills/browser-automation-skill"
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
bash "${REPO_ROOT}/scripts/browser-doctor.sh" || doctor_rc=$?

ok "install complete; next steps:"
ok "  1. /browser doctor       (verify in Claude Code)"
ok "  2. /browser add-site     (register your first site, lands in phase 2)"
if [ "${doctor_rc}" -ne 0 ]; then
  warn "doctor reported issues (exit ${doctor_rc}); run 'bash scripts/browser-doctor.sh' to review"
fi
