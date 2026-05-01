# scripts/lib/verb_helpers.sh — shared verb-script boilerplate.
# Every scripts/browser-<verb>.sh sources this AFTER common.sh + router.sh.
# See: docs/superpowers/plans/2026-05-01-phase-03-part-2-real-verbs.md Task 1.

[ -n "${BROWSER_SKILL_VERB_HELPERS_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_VERB_HELPERS_LOADED=1

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
