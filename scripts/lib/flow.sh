# scripts/lib/flow.sh — flow runner library (Phase 9 part 1-i).
#
# Three-fn API:
#   flow_parse <flow-file>       — parses YAML; sets FLOW_NAME, FLOW_SESSION,
#                                  FLOW_VARS (assoc array); emits one
#                                  {step_index, verb, args} JSON line per step
#                                  on stdout.
#   flow_apply_vars <step-json>  — reads global FLOW_VARS; substitutes ${var}
#                                  occurrences in step.args.* values; emits
#                                  modified step JSON. ${refs.NAME} passes
#                                  through literal (deferred to 9-1-ii).
#   flow_dispatch <step-json>    — translates step args → bash scripts/browser-
#                                  <verb>.sh CLI invocation; runs it; wraps
#                                  the verb's summary line into a step-event
#                                  JSON line {step_index, verb, args, status,
#                                  duration_ms, exit_code, summary} on stdout.
#
# YAML SUBSET (v1):
#   - Top-level scalars: name, session (optional)
#   - vars: block — flat key:value pairs, one per line, scalar values only
#   - steps: list of single-key flow-style maps:
#         - <verb>: { key: val, key: val }
#     OR  - <verb>: {}
#   - Top-level keys other than {name, session, vars, steps} → warn + ignore
#   - No nested maps, no list values in step bodies
#   - No multi-line strings, no block scalars
#   - ${var} substituted at parse-time via FLOW_VARS lookup
#   - ${refs.NAME} left literal (resolution in 9-1-ii)
#
# Adapters / lib helpers are LEAVES — never source verb scripts. flow_dispatch
# shells out to browser-<verb>.sh as a subprocess; the verb script is a leaf
# from this library's POV.

[ -n "${BROWSER_SKILL_FLOW_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_FLOW_LOADED=1

# Globals set by flow_parse:
#   FLOW_NAME       — string
#   FLOW_SESSION    — string (may be empty)
#   FLOW_VARS       — assoc array {key: value}
#
# Callers should `declare -gA FLOW_VARS=()` before calling flow_parse to
# reset state across multiple flows in the same shell.

flow_parse() {
  local flow_file="$1"
  [ -f "${flow_file}" ] || die "${EXIT_USAGE_ERROR}" "flow_parse: file not found: ${flow_file}"

  # Reset globals (set in caller's shell — only useful when flow_parse is
  # called WITHOUT command substitution; the `_meta` JSON line on stdout is
  # the authoritative path for subshell-captured callers like browser-flow.sh).
  FLOW_NAME=""
  FLOW_SESSION=""
  declare -gA FLOW_VARS=()

  local in_vars=0 in_steps=0
  local step_index=0
  local line stripped
  local steps_seen=0
  # Build vars JSON object for the _meta line.
  local vars_json='{}'

  while IFS= read -r line || [ -n "${line}" ]; do
    # Skip blank lines and full-line comments.
    case "${line}" in
      ''|'#'*) continue ;;
    esac

    # Top-level field detection (no leading whitespace).
    case "${line}" in
      'name:'*)
        FLOW_NAME="$(_flow_strip_value "${line#name:}")"
        in_vars=0; in_steps=0
        continue
        ;;
      'session:'*)
        FLOW_SESSION="$(_flow_strip_value "${line#session:}")"
        in_vars=0; in_steps=0
        continue
        ;;
      'vars:'*)
        in_vars=1; in_steps=0
        continue
        ;;
      'steps:'*)
        in_vars=0; in_steps=1
        steps_seen=1
        # Emit _meta line BEFORE step lines so callers can read it first.
        if [ -z "${FLOW_NAME}" ]; then
          die "${EXIT_USAGE_ERROR}" "flow_parse: missing required field 'name'"
        fi
        jq -nc \
          --arg     name "${FLOW_NAME}" \
          --arg     session "${FLOW_SESSION}" \
          --argjson vars "${vars_json}" \
          '{_kind: "meta", name: $name, session: $session, vars: $vars}'
        continue
        ;;
    esac

    if [ "${in_vars}" = "1" ]; then
      # Flat key: value indented under vars:.
      stripped="$(_flow_strip_indent "${line}")"
      case "${stripped}" in
        *': '*)
          local k v
          k="${stripped%%: *}"
          v="${stripped#*: }"
          v="$(_flow_strip_value "${v}")"
          FLOW_VARS["${k}"]="${v}"
          # Append into vars_json.
          vars_json="$(printf '%s' "${vars_json}" | jq -c --arg k "${k}" --arg v "${v}" '. + {($k): $v}')"
          ;;
      esac
      continue
    fi

    if [ "${in_steps}" = "1" ]; then
      stripped="$(_flow_strip_indent "${line}")"
      case "${stripped}" in
        '- '*)
          # New step: `- <verb>: { ... }` OR `- <verb>: {}`
          local body verb args_yaml
          body="${stripped#- }"
          verb="${body%%:*}"
          args_yaml="${body#*:}"
          args_yaml="$(_flow_strip_value "${args_yaml}")"
          local args_json
          args_json="$(_flow_inline_to_json "${args_yaml}")" \
            || die "${EXIT_USAGE_ERROR}" "flow_parse: bad step body at index ${step_index}: ${args_yaml}"
          jq -nc \
            --arg     kind "step" \
            --argjson step_index "${step_index}" \
            --arg     verb       "${verb}" \
            --argjson args       "${args_json}" \
            '{_kind: $kind, step_index: $step_index, verb: $verb, args: $args}'
          step_index=$((step_index + 1))
          ;;
      esac
      continue
    fi

    # Unknown top-level key — warn but don't fail.
    case "${line}" in
      *': '*|*':')
        printf 'flow_parse: warning: unknown top-level key in line: %s\n' "${line}" >&2
        ;;
    esac
  done < "${flow_file}"

  [ -n "${FLOW_NAME}" ] || die "${EXIT_USAGE_ERROR}" "flow_parse: missing required field 'name'"
  [ "${steps_seen}" = "1" ] || die "${EXIT_USAGE_ERROR}" "flow_parse: missing required field 'steps'"
}

# _flow_strip_value <raw> — strip leading space + trailing whitespace + quotes.
_flow_strip_value() {
  local v="$1"
  # Trim leading whitespace.
  v="${v#"${v%%[![:space:]]*}"}"
  # Trim trailing whitespace.
  v="${v%"${v##*[![:space:]]}"}"
  # Strip surrounding double or single quotes.
  case "${v}" in
    '"'*'"') v="${v#\"}"; v="${v%\"}" ;;
    "'"*"'") v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "${v}"
}

# _flow_strip_indent <line> — strip leading whitespace.
_flow_strip_indent() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  printf '%s' "${v}"
}

# _flow_inline_to_json <yaml-flow-style> → JSON object on stdout.
# Handles {} (empty), { k: v }, { k1: v1, k2: v2 }.
# Values are coerced to JSON: "true"/"false"/"null"/numbers as JSON; else
# wrapped as strings.
_flow_inline_to_json() {
  local raw="$1"
  raw="$(_flow_strip_value "${raw}")"
  case "${raw}" in
    '{}'|'') printf '{}'; return 0 ;;
    '{'*'}') ;;
    *) return 1 ;;
  esac
  # Strip outer braces.
  raw="${raw#\{}"
  raw="${raw%\}}"
  raw="$(_flow_strip_value "${raw}")"
  [ -z "${raw}" ] && { printf '{}'; return 0; }

  # Use indexed variable names ($_k0, $_k1, ...) so hyphenated YAML keys
  # like `dry-run` don't break jq's tokenizer (jq vars must match
  # [A-Za-z_][A-Za-z0-9_]*). Field names go through jq's bracket-string
  # accessor `.["dry-run"]` for the same reason.
  local jq_args=() jq_filter='. = {}'
  local IFS_orig="${IFS}"
  IFS=','
  local pair
  local idx=0
  for pair in ${raw}; do
    IFS="${IFS_orig}"
    pair="$(_flow_strip_value "${pair}")"
    [ -z "${pair}" ] && continue
    case "${pair}" in
      *': '*) ;;
      *':'*)  ;;
      *) return 1 ;;
    esac
    local k v key_jstr
    k="${pair%%:*}"
    v="${pair#*:}"
    k="$(_flow_strip_value "${k}")"
    v="$(_flow_strip_value "${v}")"
    # Coerce values to JSON: numbers / true / false / null pass as JSON; else
    # wrapped as strings. ${var} placeholders stay as strings.
    if [[ "${v}" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then
      jq_args+=(--argjson "_k${idx}" "${v}")
    elif [ "${v}" = "true" ] || [ "${v}" = "false" ] || [ "${v}" = "null" ]; then
      jq_args+=(--argjson "_k${idx}" "${v}")
    else
      jq_args+=(--arg "_k${idx}" "${v}")
    fi
    # Encode key as a JSON string for safe interpolation into the filter.
    key_jstr="$(printf '%s' "${k}" | jq -Rs .)"
    jq_filter="${jq_filter} | .[${key_jstr}] = \$_k${idx}"
    idx=$((idx + 1))
    IFS=','
  done
  IFS="${IFS_orig}"
  jq -nc "${jq_args[@]}" "${jq_filter}"
}

# flow_apply_vars <step-json> [refs-mode] — substitutes ${var} via FLOW_VARS
# and ${refs.NAME} via FLOW_REFS in step.args.* string values; emits modified
# step JSON. Both globals are assoc arrays the caller MUST declare:
#
#   declare -gA FLOW_VARS=( [key]=val ... )       # populated by flow_parse + --var
#   declare -gA FLOW_REFS=( [name]=ref ... )      # populated by browser-flow.sh
#                                                  # after each snapshot step's
#                                                  # event line (latest-wins).
#
# refs-mode (default "strict"):
#   strict — resolve ${refs.X} via FLOW_REFS or die EXIT_USAGE_ERROR (per
#            design doc §3 F3 — fail loud).
#   skip   — leave ${refs.X} as literal pass-through. Used by --dry-run, where
#            FLOW_REFS isn't populated (no snapshot has actually run).
#
# Missing FLOW_VARS[<name>] always dies EXIT_USAGE_ERROR (vars are static).
flow_apply_vars() {
  local step="$1"
  local refs_mode="${2:-strict}"
  local arg_keys
  arg_keys="$(printf '%s' "${step}" | jq -r '.args | keys[]?' 2>/dev/null || printf '')"
  local key val
  while IFS= read -r key; do
    [ -z "${key}" ] && continue
    val="$(printf '%s' "${step}" | jq -r --arg k "${key}" '.args[$k]')"
    [ "${val}" = "null" ] && continue
    # Walk all ${...} occurrences; substitute via FLOW_VARS or FLOW_REFS.
    local rest="${val}"
    local out=""
    while [[ "${rest}" == *'${'*'}'* ]]; do
      out="${out}${rest%%\$\{*}"
      rest="${rest#*\$\{}"
      local placeholder="${rest%%\}*}"
      rest="${rest#*\}}"
      case "${placeholder}" in
        refs.*)
          local ref_name="${placeholder#refs.}"
          if [ "${refs_mode}" = "skip" ]; then
            # Leave literal pass-through (dry-run mode — no snapshot has run).
            out="${out}\${${placeholder}}"
          elif [ -z "${FLOW_REFS[${ref_name}]+x}" ]; then
            die "${EXIT_USAGE_ERROR}" \
              "flow_apply_vars: undefined ref '\${${placeholder}}' in step ${key} (no snapshot has surfaced \"${ref_name}\" — add a snapshot step first OR check the accessible name)"
          else
            out="${out}${FLOW_REFS[${ref_name}]}"
          fi
          ;;
        *)
          if [ -z "${FLOW_VARS[${placeholder}]+x}" ]; then
            die "${EXIT_USAGE_ERROR}" "flow_apply_vars: undefined var '\${${placeholder}}' in step ${key}"
          fi
          out="${out}${FLOW_VARS[${placeholder}]}"
          ;;
      esac
    done
    out="${out}${rest}"
    step="$(printf '%s' "${step}" | jq -c --arg k "${key}" --arg v "${out}" '.args[$k] = $v')"
  done <<< "${arg_keys}"
  printf '%s\n' "${step}"
}

# flow_dispatch <step-json> — translates step args to a verb-script call;
# runs `bash scripts/browser-<verb>.sh --key val ...`; wraps the verb's
# summary into a step-event JSON line on stdout.
#
# For unknown verbs (no scripts/browser-<verb>.sh), emits an error step-event
# with exit_code=41 (UNSUPPORTED_OP) and status=error. flow_dispatch itself
# always returns 0 — failure surfaces in the step-event payload, NOT the
# return code (so flow execution can continue partially).
flow_dispatch() {
  local step="$1"
  local step_index verb args_obj
  step_index="$(printf '%s' "${step}" | jq -r '.step_index')"
  verb="$(printf '%s' "${step}" | jq -r '.verb')"
  args_obj="$(printf '%s' "${step}" | jq -c '.args')"

  local script="${SCRIPTS_DIR:-${REPO_ROOT:-.}/scripts}/browser-${verb}.sh"
  if [ ! -f "${script}" ]; then
    jq -nc \
      --argjson step_index "${step_index}" \
      --arg     verb "${verb}" \
      --argjson args "${args_obj}" \
      --arg     status "error" \
      --argjson exit_code 41 \
      --arg     error "no verb script at ${script}" \
      '{step_index: $step_index, verb: $verb, args: $args, status: $status, exit_code: $exit_code, error: $error}'
    return 0
  fi

  # Translate args object → CLI flags.
  local cli_flags=()
  local key val
  while IFS= read -r key; do
    [ -z "${key}" ] && continue
    val="$(printf '%s' "${args_obj}" | jq -r --arg k "${key}" '.[$k]')"
    if [ "${val}" = "true" ]; then
      # Boolean true → bare flag.
      cli_flags+=("--${key}")
    elif [ "${val}" = "false" ]; then
      # Boolean false → omit (flag absence is the false state).
      :
    else
      cli_flags+=("--${key}" "${val}")
    fi
  done <<< "$(printf '%s' "${args_obj}" | jq -r 'keys[]?')"

  local started_at_ms
  started_at_ms="$(now_ms)"

  local verb_out verb_exit
  set +e
  verb_out="$(bash "${script}" "${cli_flags[@]}" 2>&1)"
  verb_exit=$?
  set -e

  local duration_ms=$(( $(now_ms) - started_at_ms ))

  local last_line summary_json status
  last_line="$(printf '%s\n' "${verb_out}" | tail -1)"
  if printf '%s' "${last_line}" | jq -e . >/dev/null 2>&1; then
    summary_json="${last_line}"
  else
    summary_json="null"
  fi

  if [ "${verb_exit}" = "0" ]; then
    status="ok"
  else
    status="error"
  fi

  # Phase 9 part 1-ii: snapshot verbs emit an `event:snapshot` line carrying
  # `refs[]` (text → ref accessibility map). Extract it; attach as step.refs
  # so browser-flow.sh's main loop can update the global FLOW_REFS map.
  # Other verbs: refs stays null. Defensive jq -e for "no event line found".
  local refs_json="null"
  if [ "${verb}" = "snapshot" ]; then
    refs_json="$(
      printf '%s\n' "${verb_out}" \
        | jq -c -s 'map(select(.event == "snapshot")) | .[0].refs // null' 2>/dev/null \
        || printf 'null'
    )"
  fi

  jq -nc \
    --argjson step_index  "${step_index}" \
    --arg     verb        "${verb}" \
    --argjson args        "${args_obj}" \
    --arg     status      "${status}" \
    --argjson duration_ms "${duration_ms}" \
    --argjson exit_code   "${verb_exit}" \
    --argjson summary     "${summary_json}" \
    --argjson refs        "${refs_json}" \
    '{step_index: $step_index, verb: $verb, args: $args, status: $status, duration_ms: $duration_ms, exit_code: $exit_code, summary: $summary, refs: $refs}'

  return 0
}

# flow_diff_steps <old-step-event-json> <new-step-event-json> — compares two
# step events (from steps.jsonl); emits one `event:replay_diff` JSON line on
# stdout. Returns 0 if both .status AND .summary match; 1 if either diverges.
#
# Used by browser-replay.sh's per-step diff loop. Per design doc §3 F5 + plan
# 2026-05-10-phase-09-part-1-iv-replay locked decisions D1 + D4.
flow_diff_steps() {
  local old="$1"
  local new="$2"

  local step_index verb old_status new_status old_summary new_summary
  step_index="$(printf '%s' "${new}" | jq -r '.step_index')"
  verb="$(printf '%s' "${new}" | jq -r '.verb')"
  old_status="$(printf '%s' "${old}" | jq -r '.status')"
  new_status="$(printf '%s' "${new}" | jq -r '.status')"
  # Strip timing-sensitive fields before output comparison — duration_ms
  # always varies between runs and isn't a semantic difference. Per plan
  # locked decision D4 (jq-equal on summary line; future iteration could
  # add more granular per-field policies).
  old_summary="$(printf '%s' "${old}" | jq -c '.summary | del(.duration_ms)')"
  new_summary="$(printf '%s' "${new}" | jq -c '.summary | del(.duration_ms)')"

  local status_match=true
  [ "${old_status}" = "${new_status}" ] || status_match=false

  local output_match=true
  [ "${old_summary}" = "${new_summary}" ] || output_match=false

  local output_diff_json='null'
  if [ "${output_match}" = "false" ]; then
    output_diff_json="$(jq -nc \
      --argjson old "${old_summary}" \
      --argjson new "${new_summary}" \
      '{old: $old, new: $new}')"
  fi

  jq -nc \
    --arg     event         "replay_diff" \
    --argjson step_index    "${step_index}" \
    --arg     verb          "${verb}" \
    --argjson status_match  "${status_match}" \
    --arg     old_status    "${old_status}" \
    --arg     new_status    "${new_status}" \
    --argjson output_match  "${output_match}" \
    --argjson output_diff   "${output_diff_json}" \
    '{event: $event, step_index: $step_index, verb: $verb,
      status_match: $status_match, old_status: $old_status, new_status: $new_status,
      output_match: $output_match, output_diff: $output_diff}'

  if [ "${status_match}" = "true" ] && [ "${output_match}" = "true" ]; then
    return 0
  fi
  return 1
}
