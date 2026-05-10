# scripts/lib/flow_record.sh — flow recorder library (Phase 9 part 1-iii).
#
# Three-fn API:
#   flow_record_detect_password <name>
#       Returns 0 if <name> matches /password/i (case-insensitive substring).
#       Per locked decision S1: any name containing "password" (any case) is
#       a password field; recorded value is replaced with ${secrets.password}.
#
#   flow_record_transform <out-name>
#       Reads codegen JS on stdin; emits flow YAML on stdout. <out-name> is
#       the value of the YAML's `name:` field. Detects password fields per
#       flow_record_detect_password; writes ${secrets.password} placeholder
#       in their place. Emits one stderr audit line per redaction.
#
#   flow_record_emit_step <verb> <inline-args-yaml>
#       Helper: prints `  - <verb>: { ... }` step line. Used by transformer.
#
# Codegen JS patterns supported (per locked decision F6-a):
#   1. await page.goto('URL')
#   2. await page.getByRole('textbox', { name: 'X' }).click()
#   3. await page.getByRole('textbox', { name: 'X' }).fill('V')
#   4. await page.getByRole('button',  { name: 'X' }).click()
#   5. await page.locator('SELECTOR').click()       # CSS selector only
#   6. await page.locator('SELECTOR').fill('V')     # CSS selector only
#
# Out-of-scope codegen patterns (skipped with TODO comment):
#   - xpath= selectors
#   - waitForLoadState
#   - storageState (codegen's session-save)
#
# Adapter authors: this lib is INTERNAL to the flow runner; verb scripts MUST
# NOT source it directly (composition through scripts/browser-flow.sh).

[ -n "${BROWSER_SKILL_FLOW_RECORD_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_FLOW_RECORD_LOADED=1

# Globals set by flow_record_transform; readable by callers post-run.
FLOW_RECORD_PASSWORD_REDACTIONS=0
FLOW_RECORD_STEP_COUNT=0

# flow_record_detect_password <name> → exit 0 if name contains "password"
# (case-insensitive). Used by transformer to swap recorded values for the
# ${secrets.password} placeholder before persisting.
flow_record_detect_password() {
  local name="$1"
  local lower="${name,,}"
  case "${lower}" in
    *password*) return 0 ;;
    *)          return 1 ;;
  esac
}

# flow_record_emit_step <verb> <inline-args-yaml> — prints one step line.
# Inline args are the exact YAML flow-style body (e.g. '{ url: /foo }' or '{}').
flow_record_emit_step() {
  local verb="$1"
  local args_yaml="$2"
  printf '  - %s: %s\n' "${verb}" "${args_yaml}"
}

# _flow_record_emit_snapshot_if_needed
# Emits a snapshot step if the previous emitted step wasn't already a
# snapshot. Tracks via a closure-style bash global PREV_STEP_VERB.
_flow_record_emit_snapshot_if_needed() {
  if [ "${PREV_STEP_VERB:-}" != "snapshot" ]; then
    flow_record_emit_step "snapshot" "{}"
    PREV_STEP_VERB="snapshot"
    FLOW_RECORD_STEP_COUNT=$((FLOW_RECORD_STEP_COUNT + 1))
  fi
}

# flow_record_transform <out-name> → reads codegen JS on stdin; emits flow
# YAML on stdout. Detects password fields per locked decision S1; writes
# audit line on stderr per redaction.
#
# Returns 0 on success; 2 on malformed JS input.
flow_record_transform() {
  local out_name="${1:-recorded}"
  FLOW_RECORD_PASSWORD_REDACTIONS=0
  FLOW_RECORD_STEP_COUNT=0
  PREV_STEP_VERB=""

  # Header.
  printf 'name: %s\n' "${out_name}"
  printf 'steps:\n'

  local line
  while IFS= read -r line; do
    case "${line}" in
      *"page.goto("*)
        # Pattern 1: await page.goto('URL')
        local url
        url="$(_flow_record_extract_arg "${line}" 'goto')"
        [ -n "${url}" ] && {
          flow_record_emit_step "open" "{ url: ${url} }"
          PREV_STEP_VERB="open"
          FLOW_RECORD_STEP_COUNT=$((FLOW_RECORD_STEP_COUNT + 1))
        }
        ;;
      *"page.getByRole("*".click()"*|*"page.getByLabel("*".click()"*)
        # Patterns 2 + 4: getByRole(... name: 'X' ...).click()
        # OR getByLabel('X').click()
        local accessible_name
        accessible_name="$(_flow_record_extract_role_name "${line}")"
        [ -z "${accessible_name}" ] && accessible_name="$(_flow_record_extract_label "${line}")"
        [ -n "${accessible_name}" ] && {
          _flow_record_emit_snapshot_if_needed
          flow_record_emit_step "click" "{ ref: \${refs.${accessible_name}} }"
          PREV_STEP_VERB="click"
          FLOW_RECORD_STEP_COUNT=$((FLOW_RECORD_STEP_COUNT + 1))
        }
        ;;
      *"page.getByRole("*".fill("*|*"page.getByLabel("*".fill("*)
        # Pattern 3: getByRole(... name: 'X' ...).fill('V')
        local accessible_name fill_value out_value
        accessible_name="$(_flow_record_extract_role_name "${line}")"
        [ -z "${accessible_name}" ] && accessible_name="$(_flow_record_extract_label "${line}")"
        fill_value="$(_flow_record_extract_arg "${line}" 'fill')"
        [ -n "${accessible_name}" ] && {
          _flow_record_emit_snapshot_if_needed
          if flow_record_detect_password "${accessible_name}"; then
            out_value='${secrets.password}'
            FLOW_RECORD_PASSWORD_REDACTIONS=$((FLOW_RECORD_PASSWORD_REDACTIONS + 1))
            printf 'flow record: redacted password field "%s" → ${secrets.password} placeholder\n' \
              "${accessible_name}" >&2
          else
            out_value="${fill_value}"
          fi
          flow_record_emit_step "fill" "{ ref: \${refs.${accessible_name}}, text: ${out_value} }"
          PREV_STEP_VERB="fill"
          FLOW_RECORD_STEP_COUNT=$((FLOW_RECORD_STEP_COUNT + 1))
        }
        ;;
      *"page.locator("*"xpath="*)
        # XPath selectors not supported (per locked decision F6-a).
        printf '  # TODO(flow record): unsupported xpath selector — %s\n' \
          "$(_flow_record_strip_leading_ws "${line}")"
        ;;
      *"page.locator("*".click()"*)
        # Pattern 5: locator('CSS').click()
        local selector
        selector="$(_flow_record_extract_arg "${line}" 'locator')"
        [ -n "${selector}" ] && {
          flow_record_emit_step "click" "{ selector: ${selector} }"
          PREV_STEP_VERB="click"
          FLOW_RECORD_STEP_COUNT=$((FLOW_RECORD_STEP_COUNT + 1))
        }
        ;;
      *"page.locator("*".fill("*)
        # Pattern 6: locator('CSS').fill('V')
        local selector fill_value
        selector="$(_flow_record_extract_arg "${line}" 'locator')"
        fill_value="$(_flow_record_extract_arg "${line}" 'fill')"
        [ -n "${selector}" ] && [ -n "${fill_value}" ] && {
          flow_record_emit_step "fill" "{ selector: ${selector}, text: ${fill_value} }"
          PREV_STEP_VERB="fill"
          FLOW_RECORD_STEP_COUNT=$((FLOW_RECORD_STEP_COUNT + 1))
        }
        ;;
    esac
  done
}

# Helper: strip leading whitespace.
_flow_record_strip_leading_ws() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  printf '%s' "${v}"
}

# Helper: extract single-quoted arg from `<fn>(...)` invocation in a line.
# E.g. _flow_record_extract_arg "page.goto('https://example.com')" "goto"
#      → https://example.com
_flow_record_extract_arg() {
  local line="$1"
  local fn="$2"
  # Find `<fn>('...')` portion; extract between the first pair of single quotes.
  local rest="${line#*${fn}(}"
  case "${rest}" in
    "'"*)
      rest="${rest#\'}"
      printf '%s' "${rest%%\'*}"
      ;;
    *) printf '' ;;
  esac
}

# Helper: extract `name: 'X'` value from getByRole(...) call.
_flow_record_extract_role_name() {
  local line="$1"
  case "${line}" in
    *"name: '"*)
      local rest="${line#*name: \'}"
      printf '%s' "${rest%%\'*}"
      ;;
    *) printf '' ;;
  esac
}

# Helper: extract `getByLabel('X')` value.
_flow_record_extract_label() {
  local line="$1"
  case "${line}" in
    *"getByLabel('"*)
      local rest="${line#*getByLabel(\'}"
      printf '%s' "${rest%%\'*}"
      ;;
    *) printf '' ;;
  esac
}
