#!/usr/bin/env bash
# creds-migrate — move a credential from one backend to another. Fail-safe
# ordering: writes to new backend BEFORE deleting from old, so a failed
# new-backend write leaves the original credential intact.
#
# Inherits the first-use plaintext gate from creds-add: migrating TO plaintext
# requires --yes-i-know-plaintext (or a pre-existing acknowledgment marker)
# so users can't bypass the gate by going via creds-migrate.
#
# Privacy invariant: summary JSON NEVER contains the secret value.
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

name=""; to_backend=""; yes=0; yes_plaintext=0; dry_run=0

usage() {
  cat <<'USAGE'
Usage: creds-migrate --as CRED_NAME --to BACKEND [options]

  --as CRED_NAME            credential to migrate (required)
  --to BACKEND              target: keychain | libsecret | plaintext (required)
  --yes-i-know              skip the typed-name confirmation
  --yes-i-know-plaintext    acknowledge plaintext storage; required when
                            --to plaintext on a fresh box without the
                            ${CREDENTIALS_DIR}/.plaintext-acknowledged marker
  --dry-run                 print planned action; migrate nothing
  -h, --help                this message

Fail-safe: if the new-backend write fails (e.g. keychain unavailable), the
original credential is left intact. If the old-backend delete fails AFTER a
successful new-backend write, both backends transiently hold the secret —
verb logs a warning, doesn't crash; you can manually clean via creds-remove
on the old backend OR re-run creds-migrate to consolidate.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --as)                   name="$2"; shift 2 ;;
    --to)                   to_backend="$2"; shift 2 ;;
    --yes-i-know)           yes=1; shift ;;
    --yes-i-know-plaintext) yes_plaintext=1; shift ;;
    --dry-run)              dry_run=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *)                      die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

[ -n "${name}" ]       || { usage; die "${EXIT_USAGE_ERROR}" "--as is required"; }
[ -n "${to_backend}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--to is required"; }
assert_safe_name "${name}" "credential-name"

case "${to_backend}" in
  keychain|libsecret|plaintext) ;;
  *) die "${EXIT_USAGE_ERROR}" "--to must be one of {keychain, libsecret, plaintext} (got: ${to_backend})" ;;
esac

if ! credential_exists "${name}"; then
  die "${EXIT_SITE_NOT_FOUND}" "credential not found: ${name}"
fi

old_meta="$(credential_load "${name}")"
old_backend="$(printf '%s' "${old_meta}" | jq -r '.backend')"

if [ "${old_backend}" = "${to_backend}" ]; then
  die "${EXIT_USAGE_ERROR}" "credential ${name}: already on backend '${to_backend}' (no-op refused)"
fi

# First-use plaintext gate inherited from creds-add — migrating TO plaintext
# must respect the same acknowledgment requirement.
if [ "${to_backend}" = "plaintext" ]; then
  plaintext_marker="${CREDENTIALS_DIR}/.plaintext-acknowledged"
  if [ ! -f "${plaintext_marker}" ] && [ "${yes_plaintext}" -ne 1 ]; then
    die "${EXIT_USAGE_ERROR}" \
      "migrate-to-plaintext requires --yes-i-know-plaintext (or pre-create ${plaintext_marker}); plaintext stores the secret on disk and is paper security without disk encryption"
  fi
  # Touch the marker if not present (so subsequent plaintext ops skip the gate).
  if [ ! -f "${plaintext_marker}" ]; then
    mkdir -p "${CREDENTIALS_DIR}"
    chmod 700 "${CREDENTIALS_DIR}"
    ( umask 077; : > "${plaintext_marker}" )
    chmod 600 "${plaintext_marker}"
  fi
fi

started_at_ms="$(now_ms)"

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would migrate credential ${name}: ${old_backend} → ${to_backend}"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=creds-migrate tool=none why=dry-run status=ok would_run=true \
               credential="${name}" from="${old_backend}" to="${to_backend}" \
               duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

if [ "${yes}" -ne 1 ]; then
  printf 'Type the credential name (%s) to confirm migration: ' "${name}" >&2
  answer=""
  IFS= read -r answer || true
  if [ "${answer}" != "${name}" ]; then
    die "${EXIT_USAGE_ERROR}" "migration aborted (confirmation mismatch)"
  fi
fi

credential_migrate_to "${name}" "${to_backend}"
ok "credential migrated: ${name} (${old_backend} → ${to_backend})"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=creds-migrate tool=none why=migrate status=ok \
             credential="${name}" from="${old_backend}" to="${to_backend}" \
             duration_ms="${duration_ms}"
