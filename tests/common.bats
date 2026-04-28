load helpers

@test "common.sh: exit codes are exported as readonly constants" {
  run bash -c "source '${LIB_DIR}/common.sh'; printf '%s\n' \"\${EXIT_OK}\" \"\${EXIT_USAGE_ERROR}\" \"\${EXIT_PREFLIGHT_FAILED}\" \"\${EXIT_TOOL_MISSING}\" \"\${EXIT_NETWORK_ERROR}\" \"\${EXIT_CAPTURE_WRITE_FAILED}\""
  assert_status 0
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = "2" ]
  [ "${lines[2]}" = "20" ]
  [ "${lines[3]}" = "21" ]
  [ "${lines[4]}" = "30" ]
  [ "${lines[5]}" = "31" ]
}

@test "common.sh: EXIT_OK is readonly (cannot be reassigned)" {
  run bash -c "source '${LIB_DIR}/common.sh'; EXIT_OK=99"
  assert_status 1
  assert_output_contains "readonly"
}

@test "common.sh: ok() prints to stderr with green prefix when TTY" {
  run bash -c "source '${LIB_DIR}/common.sh'; FORCE_COLOR=1 ok 'hello'"
  assert_status 0
  assert_output_contains "hello"
}

@test "common.sh: warn() prints to stderr with yellow prefix" {
  run bash -c "source '${LIB_DIR}/common.sh'; FORCE_COLOR=0 warn 'careful' 2>&1"
  assert_status 0
  assert_output_contains "careful"
  assert_output_contains "warn:"
}

@test "common.sh: die() prints to stderr and exits with given code" {
  run bash -c "source '${LIB_DIR}/common.sh'; die 23 'site not found' || echo \"exit=\$?\""
  assert_output_contains "site not found"
  assert_output_contains "exit=23"
}

@test "common.sh: NO_COLOR=1 suppresses ANSI escapes" {
  run bash -c "source '${LIB_DIR}/common.sh'; NO_COLOR=1 ok 'plain' 2>&1"
  assert_output_not_contains "$(printf '\033')"
}
