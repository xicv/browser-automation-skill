#!/usr/bin/env bash
# scripts/browser-creds-totp.sh — produce the current TOTP code for a stored
# credential. Reads the base32 shared secret from the backend (`<name>:totp`
# slot stored at `creds-add --enable-totp --totp-secret-stdin` time), generates
# the RFC 6238 6-digit code via scripts/lib/node/totp.mjs, prints to stdout.
#
# Usage: bash scripts/browser-creds-totp.sh --as CRED_NAME [--dry-run]
#
# Phase-5 part 4-ii. login --auto auto-replay of TOTP codes is part 4-iii.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/credential.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/credential.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

as=""
dry_run=0

usage() {
  cat <<'USAGE'
Usage: creds-totp --as CRED_NAME [--dry-run]

  --as CRED_NAME    credential name (must be totp_enabled, must have a
                     stored TOTP secret).
  --dry-run         report planned action; emit nothing on stdout.
  -h, --help        this message

Stdout: 6-digit code (or empty on dry-run).
Stderr: human-friendly status / errors.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --as)       as="$2";  shift 2 ;;
    --dry-run)  dry_run=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

[ -n "${as}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--as is required"; }
assert_safe_name "${as}" "credential-name"

if ! credential_exists "${as}"; then
  die "${EXIT_SITE_NOT_FOUND}" "credential not found: ${as}"
fi

cred_meta="$(credential_load "${as}")"
totp_enabled="$(printf '%s' "${cred_meta}" | jq -r '.totp_enabled // false')"
if [ "${totp_enabled}" != "true" ]; then
  die "${EXIT_USAGE_ERROR}" "credential ${as} is not totp_enabled (re-add with --enable-totp --totp-secret-stdin)"
fi

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would generate TOTP code for ${as}"
  duration_ms=$(( $(now_ms) - $(printf '%s' "${SUMMARY_T0}") ))
  summary_json verb=creds-totp tool=node why=dry-run status=ok would_run=true \
               credential="${as}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

# Pipe the TOTP secret to the node generator via stdin (AP-7: never argv).
node_bin="${BROWSER_SKILL_NODE_BIN:-node}"
totp_script="${SCRIPT_DIR}/lib/node/totp.mjs"

set +e
code="$(credential_get_totp_secret "${as}" | "${node_bin}" "${totp_script}")"
gen_rc=$?
set -e

if [ "${gen_rc}" -ne 0 ]; then
  die "${EXIT_GENERIC_ERROR}" "TOTP code generation failed (rc=${gen_rc})"
fi

# Emit code on stdout — agent reads it then types into browser.
printf '%s\n' "${code}"

duration_ms=$(( $(now_ms) - $(printf '%s' "${SUMMARY_T0}") ))
summary_json verb=creds-totp tool=node why=generate-totp-code status=ok \
             credential="${as}" duration_ms="${duration_ms}"
