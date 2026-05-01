load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "verb_helpers: parse_verb_globals strips --site, --tool, --dry-run, --raw from argv" {
  run bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site prod --tool playwright-cli --foo --bar --dry-run --raw
    printf 'site=%s|tool=%s|dry=%s|raw=%s|rest=%s\n' \"\${ARG_SITE}\" \"\${ARG_TOOL}\" \"\${ARG_DRY_RUN}\" \"\${ARG_RAW}\" \"\${REMAINING_ARGV[*]}\"
  "
  assert_status 0
  assert_output_contains "site=prod"
  assert_output_contains "tool=playwright-cli"
  assert_output_contains "dry=1"
  assert_output_contains "raw=1"
  assert_output_contains "rest=--foo --bar"
}

@test "verb_helpers: parse_verb_globals leaves ARG_* unset when flags absent" {
  run bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --foo --bar
    printf 'site=[%s]|tool=[%s]|dry=[%s]|raw=[%s]|rest=%s\n' \"\${ARG_SITE:-}\" \"\${ARG_TOOL:-}\" \"\${ARG_DRY_RUN:-}\" \"\${ARG_RAW:-}\" \"\${REMAINING_ARGV[*]}\"
  "
  assert_status 0
  assert_output_contains "site=[]"
  assert_output_contains "tool=[]"
  assert_output_contains "dry=[]"
  assert_output_contains "raw=[]"
  assert_output_contains "rest=--foo --bar"
}

@test "verb_helpers: parse_verb_globals errors on --site without value" {
  run bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "site"
}

@test "verb_helpers: source_picked_adapter exits EXIT_TOOL_MISSING when adapter file missing" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    source_picked_adapter ghost-tool
  "
  assert_status "$EXIT_TOOL_MISSING"
  assert_output_contains "ghost-tool"
}

@test "verb_helpers: source_picked_adapter loads the adapter and exposes tool_metadata" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    source_picked_adapter playwright-cli
    tool_metadata
  "
  assert_status 0
  printf '%s' "${output}" | jq -e '.name == "playwright-cli"' >/dev/null
}
