load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "router: pick_tool errors EXIT_TOOL_MISSING when no rules and no --tool" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/router.sh'; pick_tool open"
  assert_status "$EXIT_TOOL_MISSING"
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
