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
