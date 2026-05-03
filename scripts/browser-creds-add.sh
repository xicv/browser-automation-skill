#!/usr/bin/env bash
# creds-add — register a credential. Smart per-OS backend select; AP-7 strict
# (password ALWAYS via stdin, never argv). Metadata in ${CREDENTIALS_DIR}/
# <name>.json mode 0600; secret payload via backend (plaintext: same dir,
# <name>.secret mode 0600; keychain/libsecret: OS vault).
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
# shellcheck source=lib/credential.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/credential.sh"
# shellcheck source=lib/secret_backend_select.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/secret_backend_select.sh"
init_paths

site=""
as=""
account=""
backend=""
auto_relogin="true"
read_stdin=0
dry_run=0

usage() {
  cat <<'USAGE'
Usage: creds-add --site SITE --as CRED_NAME --password-stdin [options]

  --site SITE              site profile name (must exist)
  --as CRED_NAME           credential name (filename, must be safe)
  --account ACCOUNT        account/email value (default: "<site>@example.com")
  --backend BACKEND        keychain | libsecret | plaintext
                            (default: smart auto-detect per OS — keychain on
                             Darwin, libsecret on Linux when secret-tool is
                             reachable, plaintext fallback otherwise)
  --auto-relogin BOOL      true | false (default: true; honest until phase-5
                            part 3's auth-flow detection lands)
  --password-stdin         REQUIRED — read password from stdin (one line);
                            this is the ONLY password-input path. AP-7
                            forbids accepting the password as an argv arg.
  --dry-run                print planned action; write nothing
  -h, --help               this message

Examples:
  printf 'mypass' | creds-add --site prod --as prod--admin --password-stdin
  printf 'mypass' | creds-add --site prod --as prod--admin --backend keychain --password-stdin
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --site)            site="$2";          shift 2 ;;
    --as)              as="$2";            shift 2 ;;
    --account)         account="$2";       shift 2 ;;
    --backend)         backend="$2";       shift 2 ;;
    --auto-relogin)    auto_relogin="$2";  shift 2 ;;
    --password-stdin)  read_stdin=1;       shift ;;
    --dry-run)         dry_run=1;          shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

[ -n "${site}" ]        || { usage; die "${EXIT_USAGE_ERROR}" "--site is required"; }
[ -n "${as}" ]          || { usage; die "${EXIT_USAGE_ERROR}" "--as is required"; }
[ "${read_stdin}" = "1" ] || { usage; die "${EXIT_USAGE_ERROR}" "--password-stdin is required (passwords MUST come via stdin per AP-7)"; }

case "${auto_relogin}" in
  true|false) ;;
  *) die "${EXIT_USAGE_ERROR}" "--auto-relogin must be 'true' or 'false' (got: ${auto_relogin})" ;;
esac

assert_safe_name "${as}" "credential-name"
[ -z "${account}" ] && account="${site}@example.com"

if ! site_exists "${site}"; then
  die "${EXIT_SITE_NOT_FOUND}" "site '${site}' not registered (try: add-site --name ${site} --url ...)"
fi

if credential_exists "${as}"; then
  die "${EXIT_USAGE_ERROR}" "credential '${as}' already exists (run: creds-remove --as ${as} first)"
fi

# Resolve backend.
if [ -z "${backend}" ]; then
  backend="$(detect_backend)"
fi
case "${backend}" in
  keychain|libsecret|plaintext) ;;
  *) die "${EXIT_USAGE_ERROR}" "--backend must be one of {keychain, libsecret, plaintext} (got: ${backend})" ;;
esac

# Read the password from stdin. `cat` consumes everything; trailing newlines
# are preserved verbatim (some users intentionally include them).
password="$(cat)"

started_at_ms="$(now_ms)"

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would write ${CREDENTIALS_DIR}/${as}.{json,secret} via backend=${backend}"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=creds-add tool=none why=dry-run status=ok would_run=true \
               credential="${as}" site="${site}" backend="${backend}" \
               duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

now_ts="$(now_iso)"
meta_json="$(jq -nc \
  --arg n "${as}" \
  --arg s "${site}" \
  --arg a "${account}" \
  --arg b "${backend}" \
  --argjson ar "${auto_relogin}" \
  --arg now "${now_ts}" \
  '{
    schema_version: 1,
    name: $n,
    site: $s,
    account: $a,
    backend: $b,
    auth_flow: "single-step-username-password",
    auto_relogin: $ar,
    totp_enabled: false,
    created_at: $now
  }')"

credential_save "${as}" "${meta_json}"

# Pipe the password into the backend via stdin (AP-7 — never argv).
printf '%s' "${password}" | credential_set_secret "${as}"

if [ "${backend}" = "plaintext" ]; then
  warn "credential '${as}' stored via plaintext backend at ${CREDENTIALS_DIR}/${as}.secret (mode 0600)"
  warn "  ensure disk encryption is enabled (FileVault/LUKS) — see 'doctor'"
fi

ok "credential added: ${as} (site=${site}, backend=${backend})"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=creds-add tool=none why=register-credential status=ok \
             credential="${as}" site="${site}" backend="${backend}" \
             duration_ms="${duration_ms}"
