#!/usr/bin/env bash
# add-site — register a site profile under sites/<name>.json.
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
init_paths

name=""; url=""; viewport="1280x800"; user_agent=""; stealth="false"
default_session=""; default_tool=""; label=""
force=0; dry_run=0

usage() {
  cat <<'USAGE'
Usage: add-site --name NAME --url URL [options]

  --name NAME              site name (required, used as filename)
  --url  URL               site URL (must start with http:// or https://)
  --viewport WxH           viewport (default 1280x800)
  --user-agent UA          override user agent
  --stealth                set stealth flag (default false)
  --default-session NAME   default session for verbs that omit --session
  --default-tool NAME      default tool for verbs that omit --tool
  --label TEXT             human-readable description
  --force                  overwrite an existing site
  --dry-run                print planned action; write nothing
  -h, --help               this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)             name="$2";              shift 2 ;;
    --url)              url="$2";               shift 2 ;;
    --viewport)         viewport="$2";          shift 2 ;;
    --user-agent)       user_agent="$2";        shift 2 ;;
    --stealth)          stealth="true";         shift ;;
    --default-session)  default_session="$2";   shift 2 ;;
    --default-tool)     default_tool="$2";      shift 2 ;;
    --label)            label="$2";             shift 2 ;;
    --force)            force=1;                shift ;;
    --dry-run)          dry_run=1;              shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

[ -n "${name}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--name is required"; }
[ -n "${url}" ]  || { usage; die "${EXIT_USAGE_ERROR}" "--url is required"; }
case "${url}" in
  http://*|https://*) ;;
  *) die "${EXIT_USAGE_ERROR}" "url must start with http:// or https:// (got: ${url})" ;;
esac
[[ "${viewport}" =~ ^[0-9]+x[0-9]+$ ]] \
  || die "${EXIT_USAGE_ERROR}" "viewport must be WIDTHxHEIGHT (got: ${viewport})"
vw="${viewport%x*}"; vh="${viewport#*x}"

started_at_ms="$(now_ms)"

if site_exists "${name}" && [ "${force}" -ne 1 ]; then
  die "${EXIT_USAGE_ERROR}" "site already exists: ${name} (use --force to overwrite)"
fi

profile_json="$(jq -nc \
  --arg n "${name}" \
  --arg u "${url}" \
  --argjson vw "${vw}" --argjson vh "${vh}" \
  --arg ua "${user_agent}" \
  --argjson stealth "${stealth}" \
  --arg ds "${default_session}" \
  --arg dt "${default_tool}" \
  --arg lbl "${label}" \
  '{
    name: $n, url: $u,
    viewport: {width: $vw, height: $vh},
    user_agent: (if $ua == "" then null else $ua end),
    stealth: $stealth,
    default_session: (if $ds == "" then null else $ds end),
    default_tool:    (if $dt == "" then null else $dt end),
    label: $lbl,
    schema_version: 1
  }')"

now_ts="$(now_iso)"
meta_json="$(jq -nc \
  --arg n "${name}" \
  --arg now "${now_ts}" \
  '{name: $n, created_at: $now, last_used_at: $now}')"

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would write ${SITES_DIR}/${name}.json"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=add-site tool=none why=dry-run status=ok would_run=true \
               site="${name}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

site_save "${name}" "${profile_json}" "${meta_json}"
ok "site added: ${name}"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=add-site tool=none why=write-profile status=ok \
             site="${name}" duration_ms="${duration_ms}"
