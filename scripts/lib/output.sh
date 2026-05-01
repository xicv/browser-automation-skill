# scripts/lib/output.sh
# Token-efficient adapter output helpers. Implements the contract from
# docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md §3.
#
# Verbs and adapters MUST emit through these helpers — never hand-roll JSON.
# Lint tier 3 (tests/lint.sh, Phase 3 Task 13) enforces it.

[ -n "${BROWSER_SKILL_OUTPUT_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_OUTPUT_LOADED=1

# Canonical status values (spec §3.1). Reject anything else at the helper boundary
# so output stays parseable by jq routing logic.
readonly _OUTPUT_STATUSES_OK="ok partial empty error aborted"

# emit_summary key=value [key=value ...]
# Required keys: verb, tool, why, status. duration_ms auto-fills from
# SUMMARY_T0 (set by caller via `SUMMARY_T0=$(now_ms)` at verb entry).
# Wraps summary_json from common.sh; adds key-presence + status-enum guards.
emit_summary() {
  local has_verb=0 has_tool=0 has_why=0 has_status=0 has_duration=0
  local arg value
  for arg in "$@"; do
    case "${arg}" in
      verb=*)         has_verb=1 ;;
      tool=*)         has_tool=1 ;;
      why=*)          has_why=1 ;;
      status=*)
        has_status=1
        value="${arg#status=}"
        if ! [[ " ${_OUTPUT_STATUSES_OK} " == *" ${value} "* ]]; then
          die "${EXIT_USAGE_ERROR}" "emit_summary: status='${value}' not in {${_OUTPUT_STATUSES_OK// /, }}"
        fi
        ;;
      duration_ms=*)  has_duration=1 ;;
    esac
  done

  [ "${has_verb}" = "1" ]   || die "${EXIT_USAGE_ERROR}" "emit_summary: missing required key 'verb'"
  [ "${has_tool}" = "1" ]   || die "${EXIT_USAGE_ERROR}" "emit_summary: missing required key 'tool'"
  [ "${has_why}" = "1" ]    || die "${EXIT_USAGE_ERROR}" "emit_summary: missing required key 'why'"
  [ "${has_status}" = "1" ] || die "${EXIT_USAGE_ERROR}" "emit_summary: missing required key 'status'"

  if [ "${has_duration}" = "0" ] && [ -n "${SUMMARY_T0:-}" ]; then
    local now elapsed
    now="$(now_ms)"
    elapsed=$((now - SUMMARY_T0))
    summary_json "$@" "duration_ms=${elapsed}"
    return
  fi

  summary_json "$@"
}

# emit_event EVENT_NAME [key=value ...]
# Streaming JSON line with `.event = EVENT_NAME`. Spec §3.3.
emit_event() {
  local event="${1:-}"
  shift || true
  [ -n "${event}" ] || die "${EXIT_USAGE_ERROR}" "emit_event: empty event name"
  summary_json "event=${event}" "$@"
}

# capture_path CATEGORY SITE EXT
# Returns ${CAPTURES_DIR}/<category>/<site>--<ts>.<ext> and mkdir -p's the parent.
# CATEGORY: snapshots | screenshots | hars | traces | videos | pdfs (spec §6).
# SITE: must pass assert_safe_name (no traversal).
# EXT: file extension without dot (e.g. png, har, yaml, webm, pdf, zip).
capture_path() {
  local category="$1" site="$2" ext="$3"
  assert_safe_name "${category}" "capture-category"
  assert_safe_name "${site}"     "site-name"
  assert_safe_name "${ext}"      "capture-extension"

  local ts
  ts="$(date -u +%Y-%m-%dT%H%M%SZ)"
  local dir="${CAPTURES_DIR:?CAPTURES_DIR not set; call init_paths first}/${category}"
  mkdir -p "${dir}"
  printf '%s/%s--%s.%s\n' "${dir}" "${site}" "${ts}" "${ext}"
}
