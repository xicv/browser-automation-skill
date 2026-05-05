#!/usr/bin/env bash
# creds-rotate-totp — re-enroll the TOTP shared secret for an existing
# credential. Use case: service forces a new TOTP secret (re-issued QR code
# during account recovery, security-incident rotation, etc.). Replaces the
# `<name>__totp` backend slot with a new value; metadata.totp_enabled stays
# true; password slot untouched.
#
# Usage: bash scripts/browser-creds-rotate-totp.sh \
#          --as CRED_NAME --totp-secret-stdin [--yes-i-know] [--dry-run]
#
# Phase-5 part 4-iv. Mirrors creds-migrate's typed-phrase confirmation.
# AP-7: TOTP secret comes via stdin only — never argv.

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

name=""; yes=0; dry_run=0; read_stdin=0

usage() {
  cat <<'USAGE'
Usage: creds-rotate-totp --as CRED_NAME --totp-secret-stdin [options]

  --as CRED_NAME           credential to rotate (must be totp_enabled).
  --totp-secret-stdin      REQUIRED — read NEW base32 TOTP secret from stdin
                            (one chunk; no NUL needed). AP-7: never argv.
  --yes-i-know             skip the typed-name confirmation prompt.
  --dry-run                print planned action; backend unchanged.
  -h, --help               this message

Behavior:
  1. Validates cred exists + is totp_enabled.
  2. Reads new TOTP secret from stdin.
  3. Typed-phrase confirmation (unless --yes-i-know).
  4. Overwrites <name>__totp backend slot.
  5. Metadata + password slot UNCHANGED.

Privacy: summary JSON NEVER includes the new TOTP secret value.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --as)                 name="$2"; shift 2 ;;
    --totp-secret-stdin)  read_stdin=1; shift ;;
    --yes-i-know)         yes=1; shift ;;
    --dry-run)            dry_run=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

[ -n "${name}" ]              || { usage; die "${EXIT_USAGE_ERROR}" "--as is required"; }
[ "${read_stdin}" -eq 1 ]     || { usage; die "${EXIT_USAGE_ERROR}" "--totp-secret-stdin is required (AP-7: secrets via stdin only)"; }
assert_safe_name "${name}" "credential-name"

if ! credential_exists "${name}"; then
  die "${EXIT_SITE_NOT_FOUND}" "credential not found: ${name}"
fi

cred_meta="$(credential_load "${name}")"
totp_enabled="$(printf '%s' "${cred_meta}" | jq -r '.totp_enabled // false')"
if [ "${totp_enabled}" != "true" ]; then
  die "${EXIT_USAGE_ERROR}" "credential ${name} is not totp_enabled (use creds-add --enable-totp instead)"
fi

# Read new TOTP secret from stdin. Single chunk — no NUL splitting needed.
new_totp="$(cat)"
if [ -z "${new_totp}" ]; then
  die "${EXIT_USAGE_ERROR}" "--totp-secret-stdin: empty secret on stdin"
fi

started_at_ms="$(now_ms)"

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would rotate TOTP secret for ${name} (${#new_totp} chars on stdin)"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=creds-rotate-totp tool=none why=dry-run status=ok would_run=true \
               credential="${name}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

if [ "${yes}" -ne 1 ]; then
  printf 'Type the credential name (%s) to confirm TOTP rotation: ' "${name}" >&2
  answer=""
  IFS= read -r answer || true
  if [ "${answer}" != "${name}" ]; then
    die "${EXIT_USAGE_ERROR}" "rotation aborted (confirmation mismatch)"
  fi
fi

# Overwrite the <name>__totp backend slot. credential_set_totp_secret reads
# stdin — pipe the new secret in.
printf '%s' "${new_totp}" | credential_set_totp_secret "${name}"

ok "TOTP secret rotated: ${name}"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=creds-rotate-totp tool=none why=rotate-totp status=ok \
             credential="${name}" duration_ms="${duration_ms}"
