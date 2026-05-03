#!/usr/bin/env bash
# creds-remove — typed-name confirmation, then delete metadata + secret via
# backend. Mirrors remove-session UX exactly: --yes-i-know skips prompt,
# --dry-run reports without writing.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/credential.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/credential.sh"
init_paths

name=""; yes=0; dry_run=0
usage() {
  cat <<'USAGE'
Usage: creds-remove --as CRED_NAME [--yes-i-know] [--dry-run]

  --as CRED_NAME    credential to remove (required)
  --yes-i-know      skip the typed-name confirmation
  --dry-run         print planned action; remove nothing
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
assert_safe_name "${name}" "credential-name"

started_at_ms="$(now_ms)"

if ! credential_exists "${name}"; then
  die "${EXIT_SITE_NOT_FOUND}" "credential not found: ${name}"
fi

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would remove credential ${name}"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=creds-remove tool=none why=dry-run status=ok would_run=true \
               credential="${name}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

if [ "${yes}" -ne 1 ]; then
  printf 'Type the credential name (%s) to confirm removal: ' "${name}" >&2
  answer=""
  IFS= read -r answer || true
  if [ "${answer}" != "${name}" ]; then
    die "${EXIT_USAGE_ERROR}" "removal aborted (confirmation mismatch)"
  fi
fi

credential_delete "${name}"
ok "credential removed: ${name}"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=creds-remove tool=none why=delete status=ok \
             credential="${name}" duration_ms="${duration_ms}"
