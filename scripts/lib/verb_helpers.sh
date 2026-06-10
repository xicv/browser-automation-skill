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
  BROWSER_SKILL_SESSION_NAME="${session_name}"
  export BROWSER_SKILL_SESSION_NAME
}

# _registry_has_live_daemon SESSION_NAME — returns 0 if the page-ownership
# registry has a live playwright-lib daemon entry for SESSION_NAME. Reads
# $BROWSER_SKILL_HOME/runtime/registry.json; treats pid dead as stale (prunes
# are done by the Node module on next read). Portable jq + kill -0 check.
_registry_has_live_daemon() {
  local session_name="${1:-default}"
  local reg_file="${BROWSER_SKILL_HOME}/runtime/registry.json"
  [ -f "${reg_file}" ] || return 1
  local pid
  pid="$(jq -r --arg s "${session_name}" '.[$s].pid // empty' "${reg_file}" 2>/dev/null)"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null
}

# --- Phase 5 part 3-ii: transparent verb-retry on EXIT_SESSION_EXPIRED -------
#
# When a verb's adapter dispatch (tool_VERB) exits 22 (EXIT_SESSION_EXPIRED)
# AND the current --site / --as has a credential with auto_relogin: true,
# silently re-login via `bash browser-login.sh --auto` and retry the verb
# EXACTLY ONCE. Per parent spec §4.4: every verb call → silent re-login →
# retry, exactly one attempt. Wires into one verb (snapshot) in this PR;
# remaining verbs in follow-ups.

# _seed_key FILE — stable identity of a storageState file (path:mtime:size),
# portable across BSD/GNU stat (GNU -c first; GNU's `stat -f` does not fail, so
# the order matters). Empty when the file is missing.
_seed_key() {
  local f="$1" m z
  [ -n "${f}" ] && [ -f "${f}" ] || { printf ''; return 0; }
  m="$(stat -c '%Y' "${f}" 2>/dev/null || stat -f '%m' "${f}" 2>/dev/null || printf '0')"
  z="$(stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null || printf '0')"
  printf '%s:%s:%s' "${f}" "${m}" "${z}"
}

# _ensure_session_cdp_endpoint — when a session is active, ensure a persistent
# browser daemon bound to THIS session is running, and export its CDP endpoint so
# every adapter attaches to the same Chrome. Restarts the daemon when the session
# (storageState identity) changes so a stale/previous-user profile is never
# reused. Also brings up the chrome-devtools-mcp daemon (attached to the same
# Chrome) when the active verb is routed to that adapter, so cdt stateful verbs
# don't fail with "requires running daemon". No-op without a session or when
# BROWSER_SKILL_AUTOSTART_DAEMON=0. --headed honored via BROWSER_SKILL_HEADED=1.
_ensure_session_cdp_endpoint() {
  # BROWSER_SKILL_AUTO_DAEMON=0 disables all auto-start (even session-based).
  [ "${BROWSER_SKILL_AUTO_DAEMON:-}" != "0" ] || return 0

  # Sessionless path: only auto-start if BROWSER_SKILL_AUTO_DAEMON=1 explicitly.
  if [ -z "${BROWSER_SKILL_STORAGE_STATE:-}" ]; then
    [ "${BROWSER_SKILL_AUTO_DAEMON:-}" = "1" ] || return 0
    # Sessionless auto-start: use "default" session name.
    export BROWSER_SKILL_SESSION_NAME="${BROWSER_SKILL_SESSION_NAME:-default}"
    local node_bin driver headed_flag state pid ep
    node_bin="${BROWSER_SKILL_NODE_BIN:-node}"
    driver="$(dirname "${BASH_SOURCE[0]}")/node/playwright-driver.mjs"
    state="${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
    headed_flag=""
    [ "${BROWSER_SKILL_HEADED:-0}" = "1" ] && headed_flag="--headed"
    pid=""
    if [ -f "${state}" ]; then
      pid="$(jq -r '.pid // empty' "${state}" 2>/dev/null)"
    fi
    if [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; then
      "${node_bin}" "${driver}" daemon-start ${headed_flag} >/dev/null 2>&1 || return 0
      # Poll for state file (pid + cdp_endpoint) up to ~10s — mirrors session path.
      local _poll_i=0
      while [ "${_poll_i}" -lt 100 ]; do
        if [ -f "${state}" ]; then
          local _poll_pid _poll_ep
          _poll_pid="$(jq -r '.pid // empty' "${state}" 2>/dev/null)"
          _poll_ep="$(jq -r '.cdp_endpoint // empty' "${state}" 2>/dev/null)"
          [ -n "${_poll_pid}" ] && [ -n "${_poll_ep}" ] && break
        fi
        sleep 0.1
        _poll_i=$((_poll_i + 1))
      done
    fi
    if [ -f "${state}" ]; then
      ep="$(jq -r '.cdp_endpoint // empty' "${state}" 2>/dev/null)"
      [ -n "${ep}" ] && export BROWSER_SKILL_CDP_ENDPOINT="${ep}"
    fi
    return 0
  fi

  # Legacy session-based gate (preserve existing BROWSER_SKILL_AUTOSTART_DAEMON behavior).
  [ "${BROWSER_SKILL_AUTOSTART_DAEMON:-1}" != "0" ] || return 0
  local node_bin driver cdt_bridge state pid ep cur_key run_key active_tool headed_flag
  node_bin="${BROWSER_SKILL_NODE_BIN:-node}"
  driver="$(dirname "${BASH_SOURCE[0]}")/node/playwright-driver.mjs"
  cdt_bridge="$(dirname "${BASH_SOURCE[0]}")/node/chrome-devtools-bridge.mjs"
  state="${BROWSER_SKILL_HOME}/playwright-lib-daemon.json"
  headed_flag=""
  [ "${BROWSER_SKILL_HEADED:-0}" = "1" ] && headed_flag="--headed"

  # Seed identity binds the daemon to one session; a change must spawn a fresh
  # profile (the node side keys profiles/<hash> off BROWSER_SKILL_SEED_KEY).
  cur_key="$(_seed_key "${BROWSER_SKILL_STORAGE_STATE}")"
  export BROWSER_SKILL_SEED_KEY="${cur_key}"

  pid=""; run_key=""
  if [ -f "${state}" ]; then
    pid="$(jq -r '.pid // empty' "${state}" 2>/dev/null)"
    run_key="$(jq -r '.seed_key // empty' "${state}" 2>/dev/null)"
  fi
  if [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; then
    # absent or crashed daemon — (re)start; daemon-start clears stale state.
    "${node_bin}" "${driver}" daemon-start ${headed_flag} >/dev/null 2>&1 || return 0
  elif [ "${run_key}" != "${cur_key}" ]; then
    # alive but bound to a DIFFERENT session — restart on the new profile.
    "${node_bin}" "${driver}" daemon-stop  >/dev/null 2>&1 || true
    "${node_bin}" "${driver}" daemon-start ${headed_flag} >/dev/null 2>&1 || return 0
  fi
  if [ -f "${state}" ]; then
    ep="$(jq -r '.cdp_endpoint // empty' "${state}" 2>/dev/null)"
    [ -n "${ep}" ] && export BROWSER_SKILL_CDP_ENDPOINT="${ep}"
  fi

  # cdt stateful verbs run through the cdt bridge's own daemon; start it attached
  # to the same Chrome when THIS verb is routed to chrome-devtools-mcp.
  active_tool="$(tool_metadata 2>/dev/null | jq -r '.name // empty' 2>/dev/null || true)"
  if [ "${active_tool}" = "chrome-devtools-mcp" ] && [ -n "${BROWSER_SKILL_CDP_ENDPOINT:-}" ]; then
    "${node_bin}" "${cdt_bridge}" daemon-start >/dev/null 2>&1 || true
  fi
  return 0
}

# invoke_with_retry VERB ARGS... — runs tool_${VERB} ARGS, returning its
# stdout + exit code. On EXIT_SESSION_EXPIRED (22), if a credential with
# auto_relogin: true exists for the resolved site/cred, runs login --auto
# silently then retries the verb ONCE. Caller sees a single stdout + final rc.
invoke_with_retry() {
  local verb="$1"
  shift

  _ensure_session_cdp_endpoint

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
  _ensure_session_cdp_endpoint

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
