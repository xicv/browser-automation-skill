load helpers

setup() {
  setup_temp_home
  TOON_BIN="${LIB_DIR}/node/toon-encode.mjs"
  export TOON_BIN
}
teardown() {
  teardown_temp_home
}

# Phase 12 (TOON output mode amendment, 2026-05-22).
# These tests pin the bridge contract: JSON on stdin -> TOON on stdout, with
# specific exit codes on failure. Every verb that opts into --format=toon
# shells through this one bridge -- so its discipline is the load-bearing
# contract for the whole feature.

@test "toon-encode: simple object encodes to TOON key:value lines" {
  out="$(printf '%s' '{"verb":"list-sites","status":"ok","count":2}' | node "${TOON_BIN}")"
  echo "${out}" | grep -q '^verb: list-sites$' \
    || fail "expected 'verb: list-sites' line; got:\n${out}"
  echo "${out}" | grep -q '^status: ok$' \
    || fail "expected 'status: ok' line; got:\n${out}"
  echo "${out}" | grep -q '^count: 2$' \
    || fail "expected 'count: 2' line; got:\n${out}"
}

@test "toon-encode: uniform array of objects collapses into TOON table header + rows" {
  input='{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}'
  out="$(printf '%s' "${input}" | node "${TOON_BIN}")"
  echo "${out}" | grep -q '^users\[2\]{id,name}:' \
    || fail "expected 'users[2]{id,name}:' header line; got:\n${out}"
  echo "${out}" | grep -q 'Alice' \
    || fail "expected Alice row; got:\n${out}"
  echo "${out}" | grep -q 'Bob' \
    || fail "expected Bob row; got:\n${out}"
}

@test "toon-encode: output ends with newline" {
  out="$(printf '%s' '{"a":1}' | node "${TOON_BIN}")"
  # bash $() strips trailing newlines; re-capture with marker.
  out_full="$(printf '%s' '{"a":1}' | node "${TOON_BIN}"; echo END)"
  [[ "${out_full}" == *$'\n'END* ]] \
    || fail "expected trailing newline before END marker; got:\n${out_full}"
}

@test "toon-encode: empty stdin returns exit 2 (EXIT_USAGE_ERROR equivalent) + stderr message" {
  run bash -c "printf '' | node \"${TOON_BIN}\""
  [ "${status}" -eq 2 ] || fail "expected exit 2; got ${status}; output:\n${output}"
  [[ "${output}" == *"empty stdin"* ]] \
    || fail "expected 'empty stdin' in stderr; got:\n${output}"
}

@test "toon-encode: invalid JSON returns exit 2 + stderr 'not JSON'" {
  run bash -c "printf 'not json' | node \"${TOON_BIN}\""
  [ "${status}" -eq 2 ] || fail "expected exit 2; got ${status}; output:\n${output}"
  [[ "${output}" == *"not JSON"* ]] \
    || fail "expected 'not JSON' message; got:\n${output}"
}

@test "toon-encode: token-bytes savings >= 30% on representative tabular payload (acceptance bar)" {
  # Per spec amendment §9 acceptance #5: --format=toon must save >=30%
  # bytes vs JSON for eligible verbs. This regression-gates the encoder
  # itself: if a future toon.mjs bump regressed table form, we'd catch it
  # before any verb-level test fired.
  local json='{"verb":"list-sites","tool":"none","why":"list","status":"ok","count":6,"sites":[{"name":"localhost-connect","url":"http://localhost:8090","label":"","default_session":null,"default_tool":null,"last_used_at":"2026-05-12T03:05:21Z"},{"name":"prod-app","url":"https://app.example.com","label":"","default_session":null,"default_tool":null,"last_used_at":"2026-04-29T07:39:33Z"},{"name":"staging-rpa","url":"https://staging.rpa.dev.avcrm.com","label":"","default_session":null,"default_tool":null,"last_used_at":"2026-05-12T03:05:21Z"},{"name":"test1","url":"https://test1.example.com","label":"","default_session":null,"default_tool":null,"last_used_at":"2026-04-29T07:04:49Z"},{"name":"test2","url":"https://test2.example.com","label":"","default_session":null,"default_tool":null,"last_used_at":"2026-04-29T07:05:10Z"},{"name":"test3","url":"https://test3.example.com","label":"","default_session":null,"default_tool":null,"last_used_at":"2026-04-29T07:05:16Z"}],"duration_ms":133}'
  local json_bytes toon toon_bytes savings_pct
  json_bytes="${#json}"
  toon="$(printf '%s' "${json}" | node "${TOON_BIN}")"
  toon_bytes="${#toon}"
  savings_pct=$(( (json_bytes - toon_bytes) * 100 / json_bytes ))
  [ "${savings_pct}" -ge 30 ] \
    || fail "expected >=30% byte savings; got json=${json_bytes}B, toon=${toon_bytes}B, savings=${savings_pct}%"
}
