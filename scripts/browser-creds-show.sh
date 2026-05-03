#!/usr/bin/env bash
# creds-show — emit credential metadata only.
#
# CRITICAL SECURITY INVARIANT: this verb NEVER emits the secret payload.
# Only the metadata sidecar (site, account, backend, auto_relogin, totp_enabled,
# created_at) is surfaced. The agent has no business seeing raw secret material;
# downstream auth flows pass the payload via stdin pipes (Phase 5 part 3 auto-
# relogin; future creds-show --reveal flow per part 2d-iii will require a
# typed-phrase confirmation before disclosure).

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

name=""
usage() { printf 'Usage: creds-show --as CRED_NAME\n'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --as) name="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
[ -n "${name}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--as is required"; }
assert_safe_name "${name}" "credential-name"

started_at_ms="$(now_ms)"

if ! credential_exists "${name}"; then
  die "${EXIT_SITE_NOT_FOUND}" "credential not found: ${name}"
fi

meta="$(credential_load "${name}")"
duration_ms=$(( $(now_ms) - started_at_ms ))

jq -cn --arg n "${name}" --argjson m "${meta}" --argjson d "${duration_ms}" \
  '{verb: "creds-show", tool: "none", why: "show", status: "ok",
    credential: $n, meta: $m, duration_ms: $d}'
