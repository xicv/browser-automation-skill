# scripts/lib/mask.sh
# Reusable masking helper for rendering sensitive values safely.
#
# mask_string VAL [SHOW_FIRST=1] [SHOW_LAST=1]
#   "password123"     → "p*********3"
#   "abc"             → "a*c"
#   "ab" / "x" / ""   → "**" / "*" / ""  (no leak; full mask)
#   long (200 chars)  → first + (cap 80 stars) + last
#
# Used by `creds show --reveal` to display a masked preview alongside the
# unmasked value, and reusable for any future verb that needs to render a
# sensitive value safely (e.g. show-credential's --masked default mode if it
# ever lands).
#
# Source from any verb / lib that needs to mask a string.
# Requires lib/common.sh sourced first (just for consistency; no deps used).

[ -n "${BROWSER_SKILL_MASK_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_MASK_LOADED=1

readonly _MASK_MIDDLE_CAP=80

mask_string() {
  local val="$1"
  local show_first="${2:-1}"
  local show_last="${3:-1}"
  local len=${#val}

  # Empty → empty.
  if [ "${len}" -eq 0 ]; then
    printf ''
    return 0
  fi

  # If reveal-budget covers the whole string, refuse to leak any chars.
  if [ "${len}" -le "$((show_first + show_last))" ]; then
    printf '%*s' "${len}" '' | tr ' ' '*'
    return 0
  fi

  local middle=$((len - show_first - show_last))
  if [ "${middle}" -gt "${_MASK_MIDDLE_CAP}" ]; then
    middle="${_MASK_MIDDLE_CAP}"
  fi

  local stars
  stars="$(printf '%*s' "${middle}" '' | tr ' ' '*')"
  printf '%s%s%s' "${val:0:${show_first}}" "${stars}" "${val: -${show_last}}"
}
