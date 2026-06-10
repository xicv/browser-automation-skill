load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() { teardown_temp_home; }

@test "inline parse: quoted comma value stays one value (regression: was exit 1)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    _flow_inline_to_json '{ selector: \"a, b\" }'
  "
  assert_status 0
  [ "${output}" = '{"selector":"a, b"}' ] || fail "unexpected output: ${output}"
}

@test "inline parse: multi-key map keeps all keys" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    _flow_inline_to_json '{ url: x, wait: load }'
  "
  assert_status 0
  [ "${output}" = '{"url":"x","wait":"load"}' ] || fail "unexpected output: ${output}"
}

@test "inline parse: bracket attribute selector unaffected" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    _flow_inline_to_json '{ selector: input[type=file] }'
  "
  assert_status 0
  [ "${output}" = '{"selector":"input[type=file]"}' ] || fail "unexpected output: ${output}"
}

@test "inline parse: bracketed value with comma stays intact" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    _flow_inline_to_json '{ selector: input[data-x=\"1,2\"] }'
  "
  assert_status 0
  [ "${output}" = '{"selector":"input[data-x=\"1,2\"]"}' ] || fail "unexpected output: ${output}"
}

@test "inline parse: empty map" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    _flow_inline_to_json '{}'
  "
  assert_status 0
  [ "${output}" = '{}' ] || fail "unexpected output: ${output}"
}

@test "inline parse: numeric + bool coercion preserved" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/flow.sh'
    _flow_inline_to_json '{ depth: 3, headed: true }'
  "
  assert_status 0
  [ "${output}" = '{"depth":3,"headed":true}' ] || fail "unexpected output: ${output}"
}
