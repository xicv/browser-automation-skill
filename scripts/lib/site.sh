# scripts/lib/site.sh
# Site profile read/write/list/delete + `current` file helpers.
# Source from any verb that needs to read or write a site profile.
# Requires lib/common.sh to be sourced first (init_paths must have run).

[ -n "${BROWSER_SKILL_SITE_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SITE_LOADED=1

# Internal: path of <name>'s profile JSON inside SITES_DIR.
_site_path() {
  printf '%s/%s.json' "${SITES_DIR}" "$1"
}

# Internal: path of <name>'s meta sidecar.
_site_meta_path() {
  printf '%s/%s.meta.json' "${SITES_DIR}" "$1"
}

# True iff a site profile JSON file exists for the given name.
site_exists() {
  [ -f "$(_site_path "$1")" ]
}

# site_save NAME PROFILE_JSON META_JSON
# Validates both JSON blobs, writes atomically (tmp + mv), mode 0600.
# Caller is responsible for shape — site.sh only validates "is it JSON".
site_save() {
  local name="$1" profile_json="$2" meta_json="$3"

  if ! printf '%s' "${profile_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "site_save: profile JSON is not valid"
  fi
  if ! printf '%s' "${meta_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "site_save: meta JSON is not valid"
  fi

  mkdir -p "${SITES_DIR}"
  chmod 700 "${SITES_DIR}"

  local profile_path meta_path profile_tmp meta_tmp
  profile_path="$(_site_path "${name}")"
  meta_path="$(_site_meta_path "${name}")"
  profile_tmp="${profile_path}.tmp.$$"
  meta_tmp="${meta_path}.tmp.$$"

  (
    umask 077
    printf '%s\n' "${profile_json}" | jq . > "${profile_tmp}"
    printf '%s\n' "${meta_json}"    | jq . > "${meta_tmp}"
  )
  chmod 600 "${profile_tmp}" "${meta_tmp}"
  mv "${profile_tmp}" "${profile_path}"
  mv "${meta_tmp}" "${meta_path}"
}
