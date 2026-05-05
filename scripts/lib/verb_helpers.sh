# scripts/lib/verb_helpers.sh — shared verb-script boilerplate.
# Every scripts/browser-<verb>.sh sources this AFTER common.sh + router.sh.
# See: docs/superpowers/plans/2026-05-01-phase-03-part-2-real-verbs.md Task 1
# and docs/superpowers/plans/2026-05-01-phase-04-real-playwright-and-sessions.md Task 3.

[ -n "${BROWSER_SKILL_VERB_HELPERS_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_VERB_HELPERS_LOADED=1

# Site + session libs are needed by resolve_session_storage_state. Source
# guards in those files prevent double-loading.
# shellcheck source=site.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/site.sh"
# shellcheck source=session.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/session.sh"

# parse_verb_globals "$@" — peels off the global flags every verb supports:
#   --site NAME           — site profile name (overrides 'current')
#   --tool NAME           — force a specific adapter (sets ARG_TOOL → router)
#   --dry-run             — print planned action, write nothing
#   --raw                 — strip streaming + summary; emit only the value (spec §4)
# Exports ARG_SITE / ARG_TOOL / ARG_DRY_RUN / ARG_RAW (unset if not present).
# Remaining argv (non-global flags) goes into REMAINING_ARGV[].
parse_verb_globals() {
  REMAINING_ARGV=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --site)
        [ -n "${2:-}" ] || die "${EXIT_USAGE_ERROR}" "--site requires a value"
        ARG_SITE="$2"; export ARG_SITE
        shift 2
        ;;
      --tool)
        [ -n "${2:-}" ] || die "${EXIT_USAGE_ERROR}" "--tool requires a value"
        ARG_TOOL="$2"; export ARG_TOOL
        shift 2
        ;;
      --as)
        [ -n "${2:-}" ] || die "${EXIT_USAGE_ERROR}" "--as requires a value"
        ARG_AS="$2"; export ARG_AS
        shift 2
        ;;
      --dry-run)
        ARG_DRY_RUN=1; export ARG_DRY_RUN
        shift
        ;;
      --raw)
        ARG_RAW=1; export ARG_RAW
        shift
        ;;
      *)
        REMAINING_ARGV+=("$1")
        shift
        ;;
    esac
  done
}

# source_picked_adapter TOOL_NAME — source $LIB_TOOL_DIR/<name>.sh in the
# current shell. Dies with EXIT_TOOL_MISSING if the file is absent.
# Caller MUST have called init_paths first (sets LIB_TOOL_DIR).
source_picked_adapter() {
  local tool="$1"
  local file="${LIB_TOOL_DIR}/${tool}.sh"
  if [ ! -f "${file}" ]; then
    die "${EXIT_TOOL_MISSING}" "adapter file not found: ${tool} (no ${file})"
  fi
  # shellcheck source=/dev/null
  source "${file}"
}

# resolve_session_storage_state — maps ARG_SITE / ARG_AS to a storageState
# file path; exports BROWSER_SKILL_STORAGE_STATE when applicable. The router's
# rule_session_required reads that env var to prefer playwright-lib (the only
# adapter declaring session_load: true).
#
# Resolution order:
#   1. If neither ARG_SITE nor ARG_AS set → no-op (export nothing).
#   2. If ARG_AS without ARG_SITE → EXIT_USAGE_ERROR (which site?).
#   3. ARG_SITE missing on disk → EXIT_SITE_NOT_FOUND (23).
#   4. Pick session: ARG_AS > site.default_session > nothing (no-op).
#   5. Session missing on disk → EXIT_SESSION_EXPIRED (22) with self-healing hint.
#   6. Session origin doesn't match site URL → EXIT_SESSION_EXPIRED (22).
#   7. Otherwise: export BROWSER_SKILL_STORAGE_STATE=<sessions-dir>/<name>.json.
resolve_session_storage_state() {
  if [ -z "${ARG_SITE:-}" ] && [ -z "${ARG_AS:-}" ]; then
    return 0
  fi
  if [ -z "${ARG_SITE:-}" ]; then
    die "${EXIT_USAGE_ERROR}" "--as requires --site (which site does this session belong to?)"
  fi

  if ! site_exists "${ARG_SITE}"; then
    die "${EXIT_SITE_NOT_FOUND}" "site '${ARG_SITE}' not registered (try: ${0##*/} add-site --name ${ARG_SITE} --url ...)"
  fi

  local profile site_url default_session session_name
  profile="$(site_load "${ARG_SITE}")"
  site_url="$(jq -r .url <<<"${profile}")"
  default_session="$(jq -r '.default_session // ""' <<<"${profile}")"

  if [ -n "${ARG_AS:-}" ]; then
    session_name="${ARG_AS}"
  elif [ -n "${default_session}" ]; then
    session_name="${default_session}"
  else
    return 0
  fi

  if ! session_exists "${session_name}"; then
    die "${EXIT_SESSION_EXPIRED}" "session '${session_name}' not found (run: ${0##*/} login --site ${ARG_SITE} --as ${session_name} --storage-state-file PATH)"
  fi

  # session_origin_check `die`s on mismatch — wrap in subshell so failure is
  # caught here and we can emit a verb-aware self-healing hint.
  if ! ( session_origin_check "${session_name}" "${site_url}" >/dev/null 2>&1 ); then
    die "${EXIT_SESSION_EXPIRED}" "session '${session_name}' origins do not match site '${ARG_SITE}' (URL ${site_url}); re-login required"
  fi

  BROWSER_SKILL_STORAGE_STATE="${SESSIONS_DIR}/${session_name}.json"
  export BROWSER_SKILL_STORAGE_STATE
}

# --- Phase 5 part 3-ii: transparent verb-retry on EXIT_SESSION_EXPIRED -------
#
# When a verb's adapter dispatch (tool_VERB) exits 22 (EXIT_SESSION_EXPIRED)
# AND the current --site / --as has a credential with auto_relogin: true,
# silently re-login via `bash browser-login.sh --auto` and retry the verb
# EXACTLY ONCE. Per parent spec §4.4: every verb call → silent re-login →
# retry, exactly one attempt. Wires into one verb (snapshot) in this PR;
# remaining verbs in follow-ups.

# invoke_with_retry VERB ARGS... — runs tool_${VERB} ARGS, returning its
# stdout + exit code. On EXIT_SESSION_EXPIRED (22), if a credential with
# auto_relogin: true exists for the resolved site/cred, runs login --auto
# silently then retries the verb ONCE. Caller sees a single stdout + final rc.
invoke_with_retry() {
  local verb="$1"
  shift

  local out rc
  set +e
  out="$(tool_"${verb}" "$@")"
  rc=$?
  set -e

  if [ "${rc}" -ne "${EXIT_SESSION_EXPIRED}" ]; then
    printf '%s' "${out}"
    return "${rc}"
  fi
  if ! _can_auto_relogin; then
    printf '%s' "${out}"
    return "${rc}"
  fi
  if ! _silent_relogin >/dev/null 2>&1; then
    printf '%s' "${out}"
    return "${rc}"
  fi

  # Re-resolve session storage state so the retry picks up the fresh file.
  resolve_session_storage_state

  set +e
  out="$(tool_"${verb}" "$@")"
  rc=$?
  set -e
  printf '%s' "${out}"
  return "${rc}"
}

# _can_auto_relogin — returns 0 iff: ARG_SITE set + a credential exists
# (resolved name = ARG_AS or site.default_session) + that credential's
# metadata declares auto_relogin: true (default for new creds per part 2d).
_can_auto_relogin() {
  [ -n "${ARG_SITE:-}" ] || return 1
  local cred_name
  cred_name="$(_resolve_relogin_cred_name 2>/dev/null)" || return 1
  [ -n "${cred_name}" ] || return 1

  # credential.sh may not be sourced in every verb script. Source on demand.
  if ! command -v credential_load >/dev/null 2>&1; then
    # shellcheck source=credential.sh
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/credential.sh" 2>/dev/null || return 1
  fi

  local cred_meta auto_relogin
  cred_meta="$(credential_load "${cred_name}" 2>/dev/null)" || return 1
  auto_relogin="$(jq -r '.auto_relogin // false' <<<"${cred_meta}" 2>/dev/null)"
  [ "${auto_relogin}" = "true" ]
}

# _resolve_relogin_cred_name — resolves the credential name for retry. Mirrors
# session-resolution: prefer ARG_AS; fall back to site's default_session;
# return non-zero if neither.
_resolve_relogin_cred_name() {
  if [ -n "${ARG_AS:-}" ]; then
    printf '%s' "${ARG_AS}"
    return 0
  fi
  if [ -n "${ARG_SITE:-}" ] && site_exists "${ARG_SITE}"; then
    local profile default_session
    profile="$(site_load "${ARG_SITE}")"
    default_session="$(jq -r '.default_session // ""' <<<"${profile}" 2>/dev/null)"
    if [ -n "${default_session}" ]; then
      printf '%s' "${default_session}"
      return 0
    fi
  fi
  return 1
}

# _silent_relogin — runs `bash browser-login.sh --auto` for the resolved cred.
# Stdout/stderr suppressed by caller (`>/dev/null 2>&1`). Returns its exit code.
_silent_relogin() {
  local cred_name
  cred_name="$(_resolve_relogin_cred_name)" || return 1
  local helpers_dir
  helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "${helpers_dir}/../browser-login.sh" --auto --site "${ARG_SITE}" --as "${cred_name}"
}
