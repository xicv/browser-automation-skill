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
auth_flow="single-step-username-password"
enable_totp=0
yes_totp=0
totp_secret_stdin=0
read_stdin=0
dry_run=0
yes_plaintext=0

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
  --auto-relogin BOOL      true | false (default: true; relogin via login --auto
                            requires auth_flow=single-step-username-password)
  --auth-flow FLOW         single-step-username-password | multi-step-username-
                            password | username-only | custom (default:
                            single-step-username-password). Only single-step is
                            supported by login --auto today; others persist
                            metadata for documentation but require --interactive
                            for relogin.
  --enable-totp            mark this credential as TOTP-enabled (phase-5 part
                            4-i: plumbing only — codegen/replay/rotation land
                            in parts 4-ii/iii/iv). Requires --yes-i-know-totp
                            (typed-phrase ack) and forbids --backend plaintext
                            (TOTP shared secrets MUST go through OS keychain /
                            libsecret per parent spec §1).
  --yes-i-know-totp        acknowledgment for --enable-totp.
  --totp-secret-stdin      read base32 TOTP shared secret from stdin AFTER
                            the password (separated by NUL byte). Stored at
                            the <name>:totp backend slot. Requires
                            --enable-totp. Phase-5 part 4-ii.
  --password-stdin         REQUIRED — read password from stdin (one line);
                            this is the ONLY password-input path. AP-7
                            forbids accepting the password as an argv arg.
  --yes-i-know-plaintext   acknowledge that the plaintext backend stores
                            the secret on disk. Required on the FIRST
                            plaintext credential add; subsequent adds skip
                            (a marker file at ${CREDENTIALS_DIR}/.plaintext-
                            acknowledged tracks acknowledgment).
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
    --auth-flow)       auth_flow="$2";     shift 2 ;;
    --enable-totp)     enable_totp=1;      shift ;;
    --yes-i-know-totp) yes_totp=1;         shift ;;
    --totp-secret-stdin) totp_secret_stdin=1; shift ;;
    --password-stdin)  read_stdin=1;       shift ;;
    --yes-i-know-plaintext) yes_plaintext=1; shift ;;
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

case "${auth_flow}" in
  single-step-username-password|multi-step-username-password|username-only|custom) ;;
  *) die "${EXIT_USAGE_ERROR}" "--auth-flow must be one of {single-step-username-password, multi-step-username-password, username-only, custom} (got: ${auth_flow})" ;;
esac

# Phase 5 part 4-i: --enable-totp requires explicit ack + forbids plaintext.
# Per parent spec §1, TOTP shared secrets are even more sensitive than
# passwords (they generate codes for the lifetime of the secret).
if [ "${enable_totp}" = "1" ] && [ "${yes_totp}" = "0" ]; then
  die "${EXIT_USAGE_ERROR}" "--enable-totp requires --yes-i-know-totp (TOTP shared secrets are highly sensitive)"
fi
if [ "${totp_secret_stdin}" = "1" ] && [ "${enable_totp}" = "0" ]; then
  die "${EXIT_USAGE_ERROR}" "--totp-secret-stdin requires --enable-totp"
fi

assert_safe_name "${as}" "credential-name"

# Phase 5 part 4-ii: prevent collisions with internal TOTP slot names.
# Internal slots use `<as>__totp` suffix; if a user picks a cred name ending
# in `__totp`, that user's password slot would alias another cred's TOTP slot.
case "${as}" in
  *__totp) die "${EXIT_USAGE_ERROR}" "credential name '${as}' reserved suffix '__totp' (collides with TOTP slot of cred '${as%__totp}')" ;;
esac
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

# Phase 5 part 4-i: TOTP-enabled creds MUST go through OS keychain / libsecret.
# plaintext on-disk storage of a TOTP shared secret means anyone with read
# access to the file can generate auth codes forever — that's worse than
# plaintext password (passwords expire/rotate; TOTP secrets typically don't).
if [ "${enable_totp}" = "1" ] && [ "${backend}" = "plaintext" ]; then
  die "${EXIT_USAGE_ERROR}" "--enable-totp forbids --backend plaintext (TOTP secrets must go through keychain or libsecret)"
fi

# First-use plaintext gate (per parent spec §1: plaintext is paper security
# without disk encryption — gate the first add behind an explicit ack).
# Marker file at ${CREDENTIALS_DIR}/.plaintext-acknowledged (mode 0600)
# tracks the user's acknowledgment; subsequent adds skip the gate silently.
if [ "${backend}" = "plaintext" ]; then
  plaintext_marker="${CREDENTIALS_DIR}/.plaintext-acknowledged"
  if [ ! -f "${plaintext_marker}" ]; then
    if [ "${yes_plaintext}" -ne 1 ]; then
      die "${EXIT_USAGE_ERROR}" \
        "first plaintext credential requires --yes-i-know-plaintext (or pre-create ${plaintext_marker}); plaintext stores the secret on disk and is paper security without disk encryption — see 'doctor' for FileVault/LUKS status"
    fi
    mkdir -p "${CREDENTIALS_DIR}"
    chmod 700 "${CREDENTIALS_DIR}"
    ( umask 077; : > "${plaintext_marker}" )
    chmod 600 "${plaintext_marker}"
  fi
fi

# Read stdin. When --totp-secret-stdin is set, stdin is `password\0totp_secret`
# (NUL-separated, AP-7: secrets never on argv); otherwise it's just the password.
# Bash `$(cat)` strips embedded NULs ("warning: ignored null byte"), so use
# `read -r -d ''` which reads up to a NUL delimiter without losing bytes.
totp_secret=""
if [ "${totp_secret_stdin}" = "1" ]; then
  IFS= read -r -d '' password || \
    die "${EXIT_USAGE_ERROR}" "--totp-secret-stdin: stdin must be 'password\\0totp_secret' (no NUL found)"
  # Second chunk: EOF-terminated (no trailing NUL required); `read` returns
  # non-zero on EOF-before-delim but still populates the variable.
  IFS= read -r -d '' totp_secret || true
  if [ -z "${totp_secret}" ]; then
    die "${EXIT_USAGE_ERROR}" "--totp-secret-stdin: stdin must be 'password\\0totp_secret' (got only one chunk)"
  fi
else
  password="$(cat)"
fi

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
totp_json="$([ "${enable_totp}" = "1" ] && printf 'true' || printf 'false')"
meta_json="$(jq -nc \
  --arg n "${as}" \
  --arg s "${site}" \
  --arg a "${account}" \
  --arg b "${backend}" \
  --argjson ar "${auto_relogin}" \
  --arg af "${auth_flow}" \
  --argjson tt "${totp_json}" \
  --arg now "${now_ts}" \
  '{
    schema_version: 1,
    name: $n,
    site: $s,
    account: $a,
    backend: $b,
    auth_flow: $af,
    auto_relogin: $ar,
    totp_enabled: $tt,
    created_at: $now
  }')"

credential_save "${as}" "${meta_json}"

# Pipe the password into the backend via stdin (AP-7 — never argv).
printf '%s' "${password}" | credential_set_secret "${as}"

# Phase 5 part 4-ii: store TOTP shared secret in the same backend at the
# `<as>:totp` slot when --totp-secret-stdin was provided.
if [ -n "${totp_secret}" ]; then
  printf '%s' "${totp_secret}" | credential_set_totp_secret "${as}"
fi

if [ "${backend}" = "plaintext" ]; then
  warn "credential '${as}' stored via plaintext backend at ${CREDENTIALS_DIR}/${as}.secret (mode 0600)"
  warn "  ensure disk encryption is enabled (FileVault/LUKS) — see 'doctor'"
fi

ok "credential added: ${as} (site=${site}, backend=${backend})"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=creds-add tool=none why=register-credential status=ok \
             credential="${as}" site="${site}" backend="${backend}" \
             duration_ms="${duration_ms}"
