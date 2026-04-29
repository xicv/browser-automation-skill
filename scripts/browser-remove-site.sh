#!/usr/bin/env bash
# remove-site — typed-name confirmation, then delete profile + meta.
# Cascade: if CURRENT_FILE points at this site, lib/site.sh::site_delete
# clears it. (Sessions / credentials linked to this site are NOT removed in
# Phase 2 — that lands with the credential lifecycle in Phase 5.)
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
init_paths

name=""; yes=0; dry_run=0
usage() {
  cat <<'USAGE'
Usage: remove-site --name NAME [--yes-i-know] [--dry-run]

  --name NAME      site to remove (required)
  --yes-i-know     skip the typed-name confirmation
  --dry-run        print planned action; remove nothing
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --name)        name="$2"; shift 2 ;;
    --yes-i-know)  yes=1; shift ;;
    --dry-run)     dry_run=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
[ -n "${name}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--name is required"; }

started_at_ms="$(now_ms)"

if ! site_exists "${name}"; then
  die "${EXIT_SITE_NOT_FOUND}" "site not found: ${name}"
fi

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would remove site ${name}"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=remove-site tool=none why=dry-run status=ok would_run=true \
               site="${name}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

if [ "${yes}" -ne 1 ]; then
  printf 'Type the site name (%s) to confirm removal: ' "${name}" >&2
  answer=""
  IFS= read -r answer || true
  if [ "${answer}" != "${name}" ]; then
    die "${EXIT_USAGE_ERROR}" "removal aborted (confirmation mismatch)"
  fi
fi

site_delete "${name}"
ok "site removed: ${name}"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=remove-site tool=none why=delete status=ok \
             site="${name}" duration_ms="${duration_ms}"
