load helpers

setup() {
  setup_temp_home
  # Source common + output so the helpers are in scope. Use a wrapper
  # bash -c so the test runs in a subshell with full pipeline control.
  OUTPUT_SH="${LIB_DIR}/output.sh"
  COMMON_SH="${LIB_DIR}/common.sh"
  export OUTPUT_SH COMMON_SH
}
teardown() {
  teardown_temp_home
}

# Phase 12 (TOON output mode amendment, 2026-05-22).
# emit_format: filter stdin through the requested output envelope.
# parse_output_format: extract --format <val> | --format=<val> from argv.

@test "parse_output_format: extracts --format=toon" {
  run bash -c "source \"${COMMON_SH}\" && source \"${OUTPUT_SH}\" && parse_output_format --format=toon"
  assert_status 0
  [ "${output}" = "toon" ] || fail "expected 'toon'; got '${output}'"
}

@test "parse_output_format: extracts --format toon (space-separated)" {
  run bash -c "source \"${COMMON_SH}\" && source \"${OUTPUT_SH}\" && parse_output_format --format toon"
  assert_status 0
  [ "${output}" = "toon" ] || fail "expected 'toon'; got '${output}'"
}

@test "parse_output_format: returns empty when no --format" {
  run bash -c "source \"${COMMON_SH}\" && source \"${OUTPUT_SH}\" && parse_output_format --foo --bar"
  assert_status 0
  [ -z "${output}" ] || fail "expected empty; got '${output}'"
}

@test "parse_output_format: --format=json explicit json" {
  run bash -c "source \"${COMMON_SH}\" && source \"${OUTPUT_SH}\" && parse_output_format --format=json"
  assert_status 0
  [ "${output}" = "json" ] || fail "expected 'json'; got '${output}'"
}

@test "emit_format json (or empty) is passthrough cat" {
  out="$(printf '%s' '{"a":1,"b":2}' | bash -c "source \"${COMMON_SH}\" && source \"${OUTPUT_SH}\" && emit_format json")"
  [ "${out}" = '{"a":1,"b":2}' ] || fail "expected passthrough; got '${out}'"
  out_empty="$(printf '%s' '{"a":1,"b":2}' | bash -c "source \"${COMMON_SH}\" && source \"${OUTPUT_SH}\" && emit_format ''")"
  [ "${out_empty}" = '{"a":1,"b":2}' ] || fail "expected passthrough on empty; got '${out_empty}'"
}

@test "emit_format toon shells to vendored TOON encoder" {
  out="$(printf '%s' '{"verb":"x","sites":[{"id":1,"name":"a"},{"id":2,"name":"b"}]}' \
    | bash -c "source \"${COMMON_SH}\" && source \"${OUTPUT_SH}\" && emit_format toon")"
  echo "${out}" | grep -q '^verb: x$' \
    || fail "expected 'verb: x' line; got:\n${out}"
  echo "${out}" | grep -q '^sites\[2\]{id,name}:' \
    || fail "expected sites table header; got:\n${out}"
}

@test "emit_format with unknown value fails EXIT_USAGE_ERROR" {
  run bash -c "printf '%s' '{}' | (source \"${COMMON_SH}\" && source \"${OUTPUT_SH}\" && emit_format yaml)"
  [ "${status}" -ne 0 ] || fail "expected non-zero; got ${status}"
  [[ "${output}" == *"unknown"* ]] || fail "expected 'unknown' in error; got '${output}'"
}
