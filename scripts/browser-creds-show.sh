#!/usr/bin/env bash
# creds-show — emit credential metadata. Optional --reveal exposes the secret
# value behind a typed-phrase confirmation gate.
#
# CRITICAL SECURITY INVARIANT (default mode): this verb NEVER emits the secret
# payload. Only the metadata sidecar (site, account, backend, auto_relogin,
# totp_enabled, created_at) is surfaced. The agent has no business seeing raw
# secret material; downstream auth flows pass the payload via stdin pipes.
#
# --reveal flow: typed-phrase confirmation (mirror remove-session UX). User
# must type the credential name back via stdin (single line). On match, the
# secret is fetched (via credential_get_secret) and emitted alongside its
# masked preview (via mask_string). On mismatch, the verb dies with a
# self-healing hint. The masked preview lets the user confirm visually they
# revealed the right thing without re-leaking the value.

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
# shellcheck source=lib/mask.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/mask.sh"
init_paths

name=""; reveal=0
usage() {
  cat <<'USAGE'
Usage: creds-show --as CRED_NAME [--reveal]

  --as CRED_NAME    credential to show (required)
  --reveal          after typed-phrase confirmation, include secret value
                    + masked preview in the output JSON
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --as)      name="$2"; shift 2 ;;
    --reveal)  reveal=1; shift ;;
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

if [ "${reveal}" -eq 1 ]; then
  printf 'Type the credential name (%s) to confirm reveal: ' "${name}" >&2
  answer=""
  IFS= read -r answer || true
  if [ "${answer}" != "${name}" ]; then
    die "${EXIT_USAGE_ERROR}" "reveal aborted (confirmation mismatch)"
  fi
  secret="$(credential_get_secret "${name}")"
  secret_masked="$(mask_string "${secret}")"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  jq -cn --arg n "${name}" --argjson m "${meta}" --arg s "${secret}" --arg sm "${secret_masked}" --argjson d "${duration_ms}" \
    '{verb: "creds-show", tool: "none", why: "reveal", status: "ok",
      credential: $n, meta: $m, secret_masked: $sm, secret: $s,
      duration_ms: $d}'
  exit "${EXIT_OK}"
fi

duration_ms=$(( $(now_ms) - started_at_ms ))
jq -cn --arg n "${name}" --argjson m "${meta}" --argjson d "${duration_ms}" \
  '{verb: "creds-show", tool: "none", why: "show", status: "ok",
    credential: $n, meta: $m, duration_ms: $d}'
