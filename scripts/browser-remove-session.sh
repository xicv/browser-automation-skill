#!/usr/bin/env bash
# remove-session — typed-name confirmation, then delete storageState + meta.
#
# Does NOT clear site.default_session pointers that reference this session.
# Dangling pointers surface clearly: `open --site X` with a deleted default
# session exits EXIT_SESSION_EXPIRED via resolve_session_storage_state with
# a self-healing "run login" hint. Cascade-clearing is Phase 5 territory.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/session.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/session.sh"
init_paths

name=""; yes=0; dry_run=0
usage() {
  cat <<'USAGE'
Usage: remove-session --as NAME [--yes-i-know] [--dry-run]

  --as NAME        session to remove (required)
  --yes-i-know     skip the typed-name confirmation
  --dry-run        print planned action; remove nothing
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --as)          name="$2"; shift 2 ;;
    --yes-i-know)  yes=1; shift ;;
    --dry-run)     dry_run=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
[ -n "${name}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--as is required"; }
assert_safe_name "${name}" "session-name"

started_at_ms="$(now_ms)"

if ! session_exists "${name}"; then
  die "${EXIT_SESSION_EXPIRED}" "session not found: ${name}"
fi

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would remove session ${name}"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=remove-session tool=none why=dry-run status=ok would_run=true \
               session="${name}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

if [ "${yes}" -ne 1 ]; then
  printf 'Type the session name (%s) to confirm removal: ' "${name}" >&2
  answer=""
  IFS= read -r answer || true
  if [ "${answer}" != "${name}" ]; then
    die "${EXIT_USAGE_ERROR}" "removal aborted (confirmation mismatch)"
  fi
fi

session_delete "${name}"
ok "session removed: ${name}"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=remove-session tool=none why=delete status=ok \
             session="${name}" duration_ms="${duration_ms}"
