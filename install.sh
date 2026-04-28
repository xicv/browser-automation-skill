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

# State dir + symlink + hooks come in tasks 11–13.
ok "preflight passed (state dir/symlink/hooks land in subsequent tasks)"
