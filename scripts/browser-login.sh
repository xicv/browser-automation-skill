#!/usr/bin/env bash
# login — capture a Playwright storageState into sessions/<name>.json.
#
# Three modes:
#   --interactive          headed Chromium; user logs in, presses Enter
#   --storage-state-file   import a hand-edited storageState file
#   --auto                 phase-5 part 3 — programmatic headless login
#                          using the stored credential (creds-add). Reads
#                          username + password (NUL-separated) from
#                          credential, sends to driver via stdin per AP-7.
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
# shellcheck source=lib/session.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/session.sh"
# shellcheck source=lib/credential.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/credential.sh"
init_paths

site=""; as=""; ss_file=""; dry_run=0; auto=0; headed=1; interactive=0

usage() {
  cat <<'USAGE'
Usage: login --site NAME --as SESSION (--storage-state-file PATH | --interactive) [--dry-run]

Capture a Playwright storageState into sessions/<SESSION>.json. Two modes:

  --interactive               Launch a headed Chromium via the playwright-lib
                              driver. User logs in interactively; press Enter
                              in this terminal to capture and save the session.
  --storage-state-file PATH   Skip the browser launch; consume an already-
                              captured storageState file (legacy hand-edit
                              path, useful for CI / non-interactive imports).
  --auto                      Programmatic headless login using the stored
                              credential (set via creds-add). Requires
                              --site + --as; the credential's auto_relogin
                              flag must be true. Username + password reach
                              the driver via stdin only (AP-7).

  --site NAME                 site profile to bind the session to (required)
  --as SESSION                session name (required; falls back to site.default_session)
  --dry-run                   validate inputs; write nothing
  --headed                    accepted (interactive mode is always headed)
  -h, --help

A site may have many sessions: pass different --as names to capture per-role
or per-account credentials (e.g. prod--admin, prod--readonly, prod--ci).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --site)                 site="$2"; shift 2 ;;
    --as)                   as="$2"; shift 2 ;;
    --storage-state-file)   ss_file="$2"; shift 2 ;;
    --interactive)          interactive=1; shift ;;
    --dry-run)              dry_run=1; shift ;;
    --headed)               headed=1; shift ;;
    --auto)                 auto=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *)                      die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

if [ "${auto}" -eq 1 ] && [ "${interactive}" -eq 1 ]; then
  die "${EXIT_USAGE_ERROR}" "--auto and --interactive are mutually exclusive"
fi
if [ "${auto}" -eq 1 ] && [ -n "${ss_file}" ]; then
  die "${EXIT_USAGE_ERROR}" "--auto and --storage-state-file are mutually exclusive"
fi
if [ "${interactive}" -eq 1 ] && [ -n "${ss_file}" ]; then
  die "${EXIT_USAGE_ERROR}" "--interactive and --storage-state-file are mutually exclusive"
fi
[ -n "${site}" ]    || { usage; die "${EXIT_USAGE_ERROR}" "--site is required"; }
# --as defaults to site.default_session if the site sets one.
if [ -z "${as}" ]; then
  default_session_from_site="$(site_load "${site}" | jq -r '.default_session // ""')"
  if [ -n "${default_session_from_site}" ]; then
    as="${default_session_from_site}"
  else
    die "${EXIT_USAGE_ERROR}" "--as is required (site ${site} has no default_session set)"
  fi
fi
assert_safe_name "${as}" "session-name"
if [ "${interactive}" -eq 0 ] && [ "${auto}" -eq 0 ] && [ -z "${ss_file}" ]; then
  usage
  die "${EXIT_USAGE_ERROR}" "--interactive, --auto, or --storage-state-file is required"
fi
if [ "${interactive}" -eq 0 ] && [ "${auto}" -eq 0 ]; then
  [ -f "${ss_file}" ] || die "${EXIT_USAGE_ERROR}" "storage-state-file not found: ${ss_file}"
fi

started_at_ms="$(now_ms)"

# Site must exist; load its URL → derive origin for binding.
profile_json="$(site_load "${site}")"   # exits 23 if missing
site_url="$(printf '%s' "${profile_json}" | jq -r .url)"
site_origin="$(url_origin "${site_url}")"

# --auto: programmatic headless login using stored credential. Validates the
# credential exists + is bound to this site + has auto_relogin=true. Loads
# the secret via credential_get_secret (dispatches to whichever backend the
# cred uses — plaintext / keychain / libsecret). Sends username\0password
# to the driver via stdin (AP-7 — secret never on argv).
if [ "${auto}" -eq 1 ]; then
  if ! credential_exists "${as}"; then
    die "${EXIT_SITE_NOT_FOUND}" "credential not found: ${as} (run: creds-add --site ${site} --as ${as} --password-stdin)"
  fi

  cred_meta="$(credential_load "${as}")"
  cred_site="$(printf '%s' "${cred_meta}" | jq -r .site)"
  cred_account="$(printf '%s' "${cred_meta}" | jq -r .account)"
  cred_auto="$(printf '%s' "${cred_meta}" | jq -r .auto_relogin)"
  cred_auth_flow="$(printf '%s' "${cred_meta}" | jq -r '.auth_flow // "single-step-username-password"')"
  cred_totp_enabled="$(printf '%s' "${cred_meta}" | jq -r '.totp_enabled // false')"

  if [ "${cred_site}" != "${site}" ]; then
    die "${EXIT_USAGE_ERROR}" "credential ${as} is bound to site '${cred_site}', not '${site}'"
  fi
  if [ "${cred_auto}" != "true" ]; then
    die "${EXIT_USAGE_ERROR}" "credential ${as} has auto_relogin=false; cannot --auto (re-add the credential or use --interactive)"
  fi
  if [ -z "${cred_account}" ] || [ "${cred_account}" = "null" ]; then
    die "${EXIT_USAGE_ERROR}" "credential ${as} has empty account; cannot --auto"
  fi
  # Phase-5 part 3-iii: only single-step-username-password is supported by
  # the playwright-driver auto-relogin path. Other auth_flow values were
  # persisted at creds-add time for documentation; relogin requires user
  # interaction.
  if [ "${cred_auth_flow}" != "single-step-username-password" ]; then
    die "${EXIT_USAGE_ERROR}" "credential ${as} has auth_flow=${cred_auth_flow}; --auto only supports single-step-username-password (use --interactive)"
  fi

  if [ "${dry_run}" -eq 1 ]; then
    ok "dry-run: would auto-relogin ${as} (site=${site}, account=${cred_account})"
    duration_ms=$(( $(now_ms) - started_at_ms ))
    summary_json verb=login tool=playwright-lib why=auto-relogin-dry-run status=ok would_run=true \
                 site="${site}" session="${as}" account="${cred_account}" \
                 duration_ms="${duration_ms}"
    exit "${EXIT_OK}"
  fi

  mkdir -p "${SESSIONS_DIR}"
  chmod 700 "${SESSIONS_DIR}"
  ss_file="${SESSIONS_DIR}/${as}.auto-tmp.$$"
  ok "auto-relogin: launching headless Chromium at ${site_url} as ${cred_account}"

  # Pipe `account\0password` to driver stdin. AP-7: secret never on argv.
  # Phase-5 part 4-iii: when cred is totp_enabled, append `\0totp_secret` so
  # the driver can replay TOTP automatically after detect2FA fires.
  set +e
  if [ "${cred_totp_enabled}" = "true" ]; then
    {
      printf '%s\0' "${cred_account}"
      credential_get_secret "${as}"
      printf '\0'
      credential_get_totp_secret "${as}"
    } | node "${SCRIPT_DIR}/lib/node/playwright-driver.mjs" auto-relogin \
          --url "${site_url}" --output-path "${ss_file}"
  else
    { printf '%s\0' "${cred_account}"; credential_get_secret "${as}"; } | \
      node "${SCRIPT_DIR}/lib/node/playwright-driver.mjs" auto-relogin \
        --url "${site_url}" --output-path "${ss_file}"
  fi
  driver_rc=${PIPESTATUS[1]}
  set -e
  if [ "${driver_rc}" = "${EXIT_AUTH_INTERACTIVE_REQUIRED}" ]; then
    # Phase-5 part 3-iv: driver detected a 2FA challenge that it couldn't
    # auto-replay (no totp_enabled cred OR replay failed). Tell the user to
    # either store a TOTP secret (creds-add --enable-totp) or fall back to
    # --interactive.
    rm -f "${ss_file}"
    die "${EXIT_AUTH_INTERACTIVE_REQUIRED}" \
        "site requires 2FA / interactive challenge — re-run with --interactive (or store a TOTP secret with creds-add --enable-totp --totp-secret-stdin)"
  fi
  if [ "${driver_rc}" -ne 0 ]; then
    rm -f "${ss_file}"
    die "${EXIT_TOOL_CRASHED}" "auto-relogin failed (driver returned ${driver_rc})"
  fi
fi

# Interactive mode: launch the driver, which opens a headed browser, waits
# for the user to press Enter, and writes the captured storageState to a
# temp file. Then we validate + save through the same pipeline as the
# storage-state-file path.
if [ "${interactive}" -eq 1 ]; then
  if [ "${dry_run}" -eq 1 ]; then
    ok "dry-run: would launch headed browser to ${site_url}, capture session ${as}"
    duration_ms=$(( $(now_ms) - started_at_ms ))
    summary_json verb=login tool=playwright-lib why=interactive-dry-run status=ok would_run=true \
                 site="${site}" session="${as}" duration_ms="${duration_ms}"
    exit "${EXIT_OK}"
  fi
  # Tempfile under SESSIONS_DIR (mode 0600 inherited from 0700 dir + driver chmod).
  mkdir -p "${SESSIONS_DIR}"
  chmod 700 "${SESSIONS_DIR}"
  ss_file="${SESSIONS_DIR}/${as}.interactive-tmp.$$"
  ok "launching headed Chromium at ${site_url}; press Enter when done logging in"
  if ! node "${SCRIPT_DIR}/lib/node/playwright-driver.mjs" login \
        --url "${site_url}" --output-path "${ss_file}"; then
    rm -f "${ss_file}"
    die "${EXIT_TOOL_CRASHED}" "interactive login failed (driver returned non-zero)"
  fi
fi

# Read & validate the storageState file.
if ! ss_json="$(jq -c . "${ss_file}" 2>/dev/null)"; then
  if [ "${interactive}" -eq 1 ] || [ "${auto}" -eq 1 ]; then
    rm -f "${ss_file}"
  fi
  die "${EXIT_USAGE_ERROR}" "storage-state-file is not valid JSON: ${ss_file}"
fi

# Origin-binding (spec §5.5): every storageState.origins[] must match site_origin.
# Empty origins[] is allowed (storageState may carry only cookies).
mismatched="$(printf '%s' "${ss_json}" | jq -r --arg target "${site_origin}" '
  [.origins[]? | select(.origin != $target) | .origin] | join(",")')"
if [ -n "${mismatched}" ]; then
  die "${EXIT_SESSION_EXPIRED}" \
    "origin mismatch: storage-state-file origins=[${mismatched}], site origin=${site_origin}"
fi

ok "site=${site} session=${as} origin=${site_origin}"

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would write ${SESSIONS_DIR}/${as}.json"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=login tool=playwright-lib why=dry-run status=ok would_run=true \
               site="${site}" session="${as}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

# Build meta sidecar.
captured_at="$(now_iso)"
if [ "${auto}" -eq 1 ]; then
  ua_tag='browser-skill playwright-lib auto-relogin'
elif [ "${interactive}" -eq 1 ]; then
  ua_tag='browser-skill playwright-lib interactive capture'
else
  ua_tag='browser-skill storageState-file import'
fi
meta_json="$(jq -nc \
  --arg n "${as}" \
  --arg s "${site}" \
  --arg o "${site_origin}" \
  --arg c "${captured_at}" \
  --arg ua "${ua_tag}" \
  '{
    name: $n, site: $s, origin: $o, captured_at: $c,
    source_user_agent: $ua, expires_in_hours: 168, schema_version: 1
  }')"

session_save "${as}" "${ss_json}" "${meta_json}"
if [ "${interactive}" -eq 1 ] || [ "${auto}" -eq 1 ]; then
  rm -f "${ss_file}"
fi
ok "session captured: ${as}"

duration_ms=$(( $(now_ms) - started_at_ms ))
if [ "${auto}" -eq 1 ]; then
  why_tag="auto-relogin"
elif [ "${interactive}" -eq 1 ]; then
  why_tag="interactive-headed-capture"
else
  why_tag="storageState-file-import"
fi
summary_json verb=login tool=playwright-lib why="${why_tag}" status=ok \
             site="${site}" session="${as}" origin="${site_origin}" \
             expires_in_hours=168 duration_ms="${duration_ms}"
