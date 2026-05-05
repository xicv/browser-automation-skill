# scripts/lib/router.sh — single source of truth for routing precedence.
# Verb scripts call pick_tool; the router returns "TOOL_NAME\tWHY".
# Adding a new precedence rule = define a function + append to ROUTING_RULES.
# Adding a new adapter that's NEVER the default for any verb = ZERO edits here
# (the adapter is reachable via --tool=<name> but won't be picked otherwise).
# See: docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md §4

[ -n "${BROWSER_SKILL_ROUTER_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_ROUTER_LOADED=1

# init_paths must have been called (LIB_TOOL_DIR is set there).
# common.sh is required (EXIT_* constants, die, _has_flag).

# ROUTING_RULES is an ordered list of rule-function names. The first rule
# whose function returns 0 (after also passing the capability filter) wins.
# Rules are appended in priority order. Add a new rule = define _rule_<name>
# function below + append its NAME to this array.
# Order matters: top-down, first-match-with-capability-support wins.
# Adding a tool that's NEVER the default for any verb = ZERO edits to this array.
ROUTING_RULES=(
  rule_session_required
  rule_capture_flags
  rule_audit_or_perf
  rule_inspect_default
  rule_extract_default
  rule_press_default
  rule_select_default
  rule_hover_default
  rule_wait_default
  rule_drag_default
  rule_default_navigation
)

# _has_flag FLAG ARGS... — returns 0 if FLAG appears in ARGS, else 1.
# Used by rule functions to detect routing-trigger flags in the verb's argv.
_has_flag() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    [ "${arg}" = "${needle}" ] && return 0
  done
  return 1
}

# _tool_supports TOOL_NAME VERB [FLAGS...] — returns 0 if the adapter declares
# support for VERB in its tool_capabilities() output, 1 otherwise. Sources the
# adapter in a subshell to keep verb-dispatch namespace clean.
_tool_supports() {
  local tool="$1" verb="$2"
  shift 2
  [ -f "${LIB_TOOL_DIR}/${tool}.sh" ] || return 1
  jq -e --arg v "${verb}" '.verbs | has($v)' >/dev/null 2>&1 <<<"$(
    # shellcheck source=/dev/null
    source "${LIB_TOOL_DIR}/${tool}.sh"
    tool_capabilities 2>/dev/null
  )"
}

# --- Precedence rules (in order). Each fn echoes "TOOL\tWHY" if it matches.
# Add a rule = define a function + append its NAME to ROUTING_RULES above.

# Session-loading required: when verb_helpers.sh::resolve_session_storage_state
# resolved a storageState file (BROWSER_SKILL_STORAGE_STATE non-empty), prefer
# playwright-lib — the only adapter declaring session_load: true.
# Reads env var (not argv) because session resolution happens before pick_tool.
rule_session_required() {
  local verb="$1"
  if [ -n "${BROWSER_SKILL_STORAGE_STATE:-}" ]; then
    case "${verb}" in
      open|click|fill|snapshot|login)
        printf 'playwright-lib\t%s\n' "session loading required (BROWSER_SKILL_STORAGE_STATE set)"
        ;;
    esac
  fi
}

# Capture flags require the dedicated console + network MCP tools that only
# chrome-devtools-mcp exposes (per parent spec Appendix B). Triggered by
# `--capture-console` or `--capture-network` on any verb.
rule_capture_flags() {
  local verb="$1"
  shift
  if _has_flag --capture-console "$@" || _has_flag --capture-network "$@"; then
    printf 'chrome-devtools-mcp\t%s\n' "--capture-* requested (only cdt-mcp exposes console/network MCP tools)"
  fi
}

# Lighthouse + perf-trace verbs/flags route to chrome-devtools-mcp — only
# adapter with `lighthouse_audit` and `performance_*` MCP tools (Appendix B).
rule_audit_or_perf() {
  local verb="$1"
  shift
  case "${verb}" in
    audit)
      printf 'chrome-devtools-mcp\t%s\n' "verb=audit (only cdt-mcp has lighthouse/perf)"
      return 0
      ;;
  esac
  if _has_flag --lighthouse "$@" || _has_flag --perf-trace "$@"; then
    printf 'chrome-devtools-mcp\t%s\n' "--lighthouse/--perf-trace requested (only cdt-mcp has them)"
  fi
}

# Default tool for `inspect` per parent spec Appendix B — chrome-devtools-mcp
# is the only adapter with dedicated console + network + screenshot MCP tools
# bundled into a single inspection surface.
rule_inspect_default() {
  local verb="$1"
  case "${verb}" in
    inspect)
      printf 'chrome-devtools-mcp\t%s\n' "inspect default per Appendix B"
      ;;
  esac
}

# Default tool for `extract` per parent spec Appendix B — chrome-devtools-mcp
# pairs `evaluate_script` with `list_network_requests` for selector/eval +
# multi-URL inspection. NOTE: `--scrape <urls...>` should route to obscura
# when it lands (Phase 8); prepend a higher-precedence obscura rule above
# this one then — no edits needed here.
rule_extract_default() {
  local verb="$1"
  case "${verb}" in
    extract)
      printf 'chrome-devtools-mcp\t%s\n' "extract default per Appendix B"
      ;;
  esac
}

# Phase-6 part 1: keyboard press routes to chrome-devtools-mcp. cdt-mcp's
# `press_key` MCP tool is the canonical input mechanism; playwright-cli/lib
# don't declare press today (could be added later via their respective
# `keyboard.press` APIs).
rule_press_default() {
  local verb="$1"
  case "${verb}" in
    press)
      printf 'chrome-devtools-mcp\t%s\n' "press default (only cdt-mcp declares press today)"
      ;;
  esac
}

# Phase-6 part 2: <select> option pick routes to chrome-devtools-mcp.
# Stateful — requires daemon (refMap precondition). MCP `select_option` tool
# accepts uid + one of value/label/index.
rule_select_default() {
  local verb="$1"
  case "${verb}" in
    select)
      printf 'chrome-devtools-mcp\t%s\n' "select default (only cdt-mcp declares select today)"
      ;;
  esac
}

# Phase-6 part 3: pointer hover routes to chrome-devtools-mcp. Stateful —
# requires daemon (refMap precondition). MCP `hover` tool accepts uid.
rule_hover_default() {
  local verb="$1"
  case "${verb}" in
    hover)
      printf 'chrome-devtools-mcp\t%s\n' "hover default (only cdt-mcp declares hover today)"
      ;;
  esac
}

# Phase-6 part 4: explicit wait for an element state. Stateless — no refMap
# required (selector-based). MCP `wait_for` tool accepts {selector, state,
# timeout}. Routes one-shot or daemon-routed (parallel to eval/audit).
rule_wait_default() {
  local verb="$1"
  case "${verb}" in
    wait)
      printf 'chrome-devtools-mcp\t%s\n' "wait default (only cdt-mcp declares wait today)"
      ;;
  esac
}

# Phase-6 part 5: pointer drag (src → dst by refs). Stateful — requires
# daemon (refMap precondition for both src + dst). MCP `drag` tool accepts
# {src_uid, dst_uid}.
rule_drag_default() {
  local verb="$1"
  case "${verb}" in
    drag)
      printf 'chrome-devtools-mcp\t%s\n' "drag default (only cdt-mcp declares drag today)"
      ;;
  esac
}

# Default for navigation/inspection verbs — playwright-cli is the cheap,
# stable, multi-browser default per parent spec Appendix B.
rule_default_navigation() {
  local verb="$1"
  case "${verb}" in
    open|click|fill|snapshot)
      printf 'playwright-cli\t%s\n' "default for ${verb}"
      ;;
  esac
}

# pick_tool VERB [FLAGS...] — echoes "TOOL_NAME\tWHY" on success.
# Two-stage:
#   1. --tool=X (via $ARG_TOOL env var): validate X exists + supports verb.
#   2. Walk ROUTING_RULES top-down. First matching rule whose tool ALSO
#      passes the capability filter wins.
# On exhaustion: dies with EXIT_TOOL_MISSING.
pick_tool() {
  local verb="$1"
  shift

  if [ -n "${ARG_TOOL:-}" ]; then
    if [ ! -f "${LIB_TOOL_DIR}/${ARG_TOOL}.sh" ]; then
      die "${EXIT_USAGE_ERROR}" "--tool=${ARG_TOOL}: no such adapter (no ${LIB_TOOL_DIR}/${ARG_TOOL}.sh)"
    fi
    if ! _tool_supports "${ARG_TOOL}" "${verb}" "$@"; then
      die "${EXIT_USAGE_ERROR}" "--tool=${ARG_TOOL} does not support verb=${verb} (per tool_capabilities)"
    fi
    printf '%s\t%s\n' "${ARG_TOOL}" "user-specified"
    return 0
  fi

  local rule
  for rule in "${ROUTING_RULES[@]}"; do
    local rule_out
    rule_out="$("${rule}" "${verb}" "$@" 2>/dev/null || true)"
    [ -z "${rule_out}" ] && continue

    local picked_tool picked_why
    picked_tool="${rule_out%%$'\t'*}"
    picked_why="${rule_out#*$'\t'}"

    if _tool_supports "${picked_tool}" "${verb}" "$@"; then
      printf '%s\t%s\n' "${picked_tool}" "${picked_why}"
      return 0
    fi
    warn "router: rule ${rule} picked ${picked_tool} but it doesn't support verb=${verb}; falling through"
  done

  die "${EXIT_TOOL_MISSING}" "no adapter supports verb=${verb} with flags: $*"
}
