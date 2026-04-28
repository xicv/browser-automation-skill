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
