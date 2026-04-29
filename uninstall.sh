#!/usr/bin/env bash
# uninstall.sh — remove the ~/.claude/skills symlink. Optionally remove state.
set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

KEEP_STATE=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: ./uninstall.sh [options]

  --keep-state     do not delete ~/.browser-skill/ (default; today the script
                   never deletes state — a future release may add an opt-in
                   --delete-state flag)
  --dry-run        print what would happen, change nothing
  -h, --help
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --keep-state) KEEP_STATE=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            warn "ignoring unknown arg: ${arg}" ;;
  esac
done

init_paths

link="${HOME}/.claude/skills/browser-automation-skill"
if [ -L "${link}" ]; then
  if [ "${DRY_RUN}" = "1" ]; then
    ok "dry-run: would remove symlink ${link}"
  else
    rm "${link}"
    ok "removed symlink: ${link}"
  fi
else
  ok "no symlink at ${link} (already gone)"
fi

if [ "${KEEP_STATE}" != "1" ] && [ -d "${BROWSER_SKILL_HOME}" ]; then
  ok "keeping state at ${BROWSER_SKILL_HOME} (use rm -rf manually to delete)"
fi
