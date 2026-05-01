load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "output: emit_summary requires verb, tool, why, status" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/output.sh'; emit_summary"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "verb"
}

@test "output: emit_summary emits one line of valid JSON with all required keys" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/output.sh'; emit_summary verb=open tool=playwright-cli why=default status=ok duration_ms=42"
  assert_status 0
  [ "${#lines[@]}" -eq 1 ]
  printf '%s' "${output}" | jq -e '.verb and .tool and .why and .status and .duration_ms' >/dev/null
}

@test "output: emit_summary auto-fills duration_ms when SUMMARY_T0 is set" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/output.sh'; SUMMARY_T0=\$(now_ms); sleep 0.05; emit_summary verb=test tool=none why=test status=ok"
  assert_status 0
  printf '%s' "${output}" | jq -e '.duration_ms | type == "number" and . >= 0' >/dev/null
}

@test "output: emit_summary status enum guard rejects unknown statuses" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/output.sh'; emit_summary verb=test tool=none why=test status=banana"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "status"
}

@test "output: emit_summary accepts the five canonical status values" {
  for s in ok partial empty error aborted; do
    run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/output.sh'; emit_summary verb=test tool=none why=test status=${s}"
    [ "${status}" = "0" ] || fail "status=${s} unexpectedly rejected"
  done
}

@test "output: emit_event emits one line of JSON with .event key" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/output.sh'; emit_event navigated url=https://example.com/dashboard"
  assert_status 0
  [ "${#lines[@]}" -eq 1 ]
  [ "$(printf '%s' "${output}" | jq -r .event)" = "navigated" ]
  [ "$(printf '%s' "${output}" | jq -r .url)" = "https://example.com/dashboard" ]
}

@test "output: emit_event rejects empty event name" {
  run bash -c "source '${LIB_DIR}/common.sh'; source '${LIB_DIR}/output.sh'; emit_event ''"
  assert_status "$EXIT_USAGE_ERROR"
}

@test "output: capture_path generates standard path for a category + site" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/output.sh'; capture_path screenshots prod png"
  assert_status 0
  [[ "${output}" =~ /captures/screenshots/prod--[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.png$ ]] \
    || fail "expected captures/screenshots/<site>--<ts>.png path, got: ${output}"
}

@test "output: capture_path rejects unsafe site (path traversal)" {
  for bad in '../evil' 'foo/bar' 'foo bar' ''; do
    run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/output.sh'; capture_path screenshots '${bad}' png"
    [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR for site='${bad}', got ${status}"
  done
}

@test "output: capture_path mkdir -p's the parent directory" {
  result="$(bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/output.sh'; capture_path hars prod har")"
  parent_dir="$(dirname "${result}")"
  [ -d "${parent_dir}" ] || fail "expected parent dir ${parent_dir} to exist"
}
