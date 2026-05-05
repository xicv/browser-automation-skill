load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "router: pick_tool with --tool=X for non-existent X exits USAGE_ERROR" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/router.sh'; ARG_TOOL=ghost-tool pick_tool open"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "router: _tool_supports returns 1 for non-existent adapter" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/router.sh'; _tool_supports ghost-tool open"
  assert_status 1
}

@test "router: ROUTING_RULES is an array (initially empty before any rules added)" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/router.sh'; declare -p ROUTING_RULES"
  assert_status 0
  assert_output_contains "declare -a ROUTING_RULES"
}

@test "router: _has_flag detects flag presence in argv list" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/router.sh'; if _has_flag --foo --bar --foo --baz; then echo found; else echo missing; fi"
  assert_status 0
  [ "${output}" = "found" ]
}

@test "router: _has_flag returns 1 when flag absent" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/router.sh'; if _has_flag --foo --bar --baz; then echo found; else echo missing; fi"
  assert_status 0
  [ "${output}" = "missing" ]
}

@test "router: rule_default_navigation picks playwright-cli for verb=open" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool open
  "
  assert_status 0
  assert_output_contains "playwright-cli"
  assert_output_contains "default"
}

@test "router: rule_default_navigation picks playwright-cli for verb=snapshot" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool snapshot
  "
  assert_status 0
  assert_output_contains "playwright-cli"
}

@test "router: --tool=playwright-cli explicit override returns playwright-cli with reason 'user-specified'" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    ARG_TOOL=playwright-cli pick_tool open
  "
  assert_status 0
  assert_output_contains "playwright-cli"
  assert_output_contains "user-specified"
}

@test "router: --tool=playwright-cli for verb=audit fails USAGE_ERROR (capability filter rejects)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    ARG_TOOL=playwright-cli pick_tool audit
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}

# --- Phase 5 part 1d — promotion rules for cdt-mcp ---

@test "router (1d): --capture-console on snapshot routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool snapshot --capture-console
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "capture"
}

@test "router (1d): --capture-network on snapshot routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool snapshot --capture-network
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
}

@test "router (1d): verb=audit (no --tool) routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool audit
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
}

@test "router (1d): --lighthouse on any verb routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool snapshot --lighthouse
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
}

@test "router (1d): --perf-trace on any verb routes to chrome-devtools-mcp" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool snapshot --perf-trace
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
}

@test "router (1d): verb=inspect routes to chrome-devtools-mcp by default" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool inspect
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
  assert_output_contains "Appendix B"
}

@test "router (1d): verb=extract routes to chrome-devtools-mcp by default" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool extract
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
}

@test "router (1d): --capture-console wins over default-navigation (open --capture-console → cdt-mcp)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool open --capture-console
  "
  assert_status 0
  assert_output_contains "chrome-devtools-mcp"
}

@test "router (1d): plain open (no flags) still picks playwright-cli (regression guard)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool open
  "
  assert_status 0
  assert_output_contains "playwright-cli"
  assert_output_contains "default"
}

@test "router (1d): session_required wins over capture-flag rule (storage state set + --capture-console → playwright-lib)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    BROWSER_SKILL_STORAGE_STATE=/tmp/x.json pick_tool snapshot --capture-console
  "
  assert_status 0
  assert_output_contains "playwright-lib"
  assert_output_contains "session loading"
}

@test "router (1d): --tool=playwright-cli for verb=inspect still rejected by capability filter (preserves existing behavior)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    ARG_TOOL=playwright-cli pick_tool inspect
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "does not support"
}
