load helpers

# Phase 7 part 1-ii: lib/sanitize.sh — pure jq-function library.
# Two functions: sanitize_har / sanitize_console. No verb integration.
# Per parent spec §8.3: sentinel string is "***REDACTED***" for header values
# and "***" for URL param values + console field values.

setup() {
  setup_temp_home
  init_paths
  source "${LIB_DIR}/sanitize.sh"
  SANITIZE_FIXTURES="${BATS_TEST_DIRNAME}/fixtures/sanitize"
}
teardown() { teardown_temp_home; }

# ---------- sanitize_har — header redaction ----------

@test "sanitize_har: Authorization request header redacted to sentinel" {
  out="$(sanitize_har < "${SANITIZE_FIXTURES}/har-with-auth.json")"
  printf '%s' "${out}" \
    | jq -e '.log.entries[0].request.headers | map(select(.name == "Authorization")) | .[0].value == "***REDACTED***"' >/dev/null
}

@test "sanitize_har: Cookie request header redacted" {
  out="$(sanitize_har < "${SANITIZE_FIXTURES}/har-with-auth.json")"
  printf '%s' "${out}" \
    | jq -e '.log.entries[0].request.headers | map(select(.name == "Cookie")) | .[0].value == "***REDACTED***"' >/dev/null
}

@test "sanitize_har: X-API-Key request header redacted (case-insensitive name match)" {
  out="$(sanitize_har < "${SANITIZE_FIXTURES}/har-with-auth.json")"
  printf '%s' "${out}" \
    | jq -e '.log.entries[0].request.headers | map(select(.name == "X-API-Key")) | .[0].value == "***REDACTED***"' >/dev/null
}

@test "sanitize_har: Set-Cookie response header redacted" {
  out="$(sanitize_har < "${SANITIZE_FIXTURES}/har-with-auth.json")"
  printf '%s' "${out}" \
    | jq -e '.log.entries[0].response.headers | map(select(.name == "Set-Cookie")) | .[0].value == "***REDACTED***"' >/dev/null
}

@test "sanitize_har: Authorization response header redacted" {
  out="$(sanitize_har < "${SANITIZE_FIXTURES}/har-with-auth.json")"
  printf '%s' "${out}" \
    | jq -e '.log.entries[0].response.headers | map(select(.name == "Authorization")) | .[0].value == "***REDACTED***"' >/dev/null
}

@test "sanitize_har: non-sensitive headers unchanged" {
  out="$(sanitize_har < "${SANITIZE_FIXTURES}/har-with-auth.json")"
  printf '%s' "${out}" \
    | jq -e '.log.entries[0].request.headers | map(select(.name == "Accept")) | .[0].value == "application/json"' >/dev/null
  printf '%s' "${out}" \
    | jq -e '.log.entries[0].response.headers | map(select(.name == "Content-Type")) | .[0].value == "application/json"' >/dev/null
}

# ---------- sanitize_har — URL param masking ----------

@test "sanitize_har: api_key URL param masked, name preserved" {
  out="$(sanitize_har < "${SANITIZE_FIXTURES}/har-with-auth.json")"
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("api_key=***")' >/dev/null
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("SECRET123") | not' >/dev/null
}

@test "sanitize_har: multi-param URL — all sensitive masked, others preserved" {
  out="$(sanitize_har < "${SANITIZE_FIXTURES}/har-multi-params.json")"
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("api_key=***")' >/dev/null
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("token=***")' >/dev/null
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("access_token=***")' >/dev/null
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("client_secret=***")' >/dev/null
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("page=2")' >/dev/null
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("limit=10")' >/dev/null
  # Sensitive raw values must not survive.
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("AAA") | not' >/dev/null
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("BBB") | not' >/dev/null
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("CCC") | not' >/dev/null
  printf '%s' "${out}" | jq -e '.log.entries[0].request.url | contains("DDD") | not' >/dev/null
}

# ---------- sanitize_har — idempotency + clean-input passthrough ----------

@test "sanitize_har: idempotent (running twice = running once)" {
  once="$(sanitize_har < "${SANITIZE_FIXTURES}/har-with-auth.json")"
  twice="$(printf '%s' "${once}" | sanitize_har)"
  [ "${once}" = "${twice}" ] || fail "double-sanitize differs from single-sanitize"
}

@test "sanitize_har: clean HAR (no sensitive headers/params) unchanged" {
  in="$(cat "${SANITIZE_FIXTURES}/har-clean.json" | jq -c .)"
  out="$(sanitize_har < "${SANITIZE_FIXTURES}/har-clean.json" | jq -c .)"
  [ "${in}" = "${out}" ] || fail "clean HAR was modified by sanitize"
}

# ---------- sanitize_console ----------

@test "sanitize_console: password field value masked (case-insensitive key)" {
  out="$(sanitize_console < "${SANITIZE_FIXTURES}/console-with-secrets.json")"
  printf '%s' "${out}" | jq -e '.[1].text | contains("password: ***")' >/dev/null
  printf '%s' "${out}" | jq -e '.[1].text | contains("hunter2") | not' >/dev/null
}

@test "sanitize_console: token + secret field values masked" {
  out="$(sanitize_console < "${SANITIZE_FIXTURES}/console-with-secrets.json")"
  printf '%s' "${out}" | jq -e '.[2].text | contains("token: ***")' >/dev/null
  printf '%s' "${out}" | jq -e '.[2].text | contains("abc123def456") | not' >/dev/null
  printf '%s' "${out}" | jq -e '.[3].text | contains("secret: ***")' >/dev/null
  printf '%s' "${out}" | jq -e '.[3].text | contains("xyz789") | not' >/dev/null
}

@test "sanitize_console: non-sensitive messages unchanged" {
  out="$(sanitize_console < "${SANITIZE_FIXTURES}/console-with-secrets.json")"
  printf '%s' "${out}" | jq -e '.[0].text == "user logged in"' >/dev/null
  printf '%s' "${out}" | jq -e '.[4].text == "page rendered in 42ms"' >/dev/null
}

@test "sanitize_console: clean console array unchanged" {
  in="$(cat "${SANITIZE_FIXTURES}/console-clean.json" | jq -c .)"
  out="$(sanitize_console < "${SANITIZE_FIXTURES}/console-clean.json" | jq -c .)"
  [ "${in}" = "${out}" ] || fail "clean console was modified by sanitize"
}

@test "sanitize_console: idempotent" {
  once="$(sanitize_console < "${SANITIZE_FIXTURES}/console-with-secrets.json")"
  twice="$(printf '%s' "${once}" | sanitize_console)"
  [ "${once}" = "${twice}" ] || fail "double-sanitize-console differs from single-sanitize"
}
