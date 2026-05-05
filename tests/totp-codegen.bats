load helpers

# Phase 5 part 4-ii: pure-node TOTP generator. Validate against RFC 6238 §A
# test vectors (Appendix A of the RFC). The shared secret used is the ASCII
# bytes of "12345678901234567890" base32-encoded → "GEZDGNBVGY3TQOJQGEZDGNBV
# GY3TQOJQ".

setup() {
  setup_temp_home
  TOTP_SCRIPT="${SCRIPTS_DIR}/lib/node/totp.mjs"
  RFC_SECRET="GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
}
teardown() { teardown_temp_home; }

# RFC 6238 §A test vectors (SHA1, 8 digits).
@test "totp.mjs (4-ii): RFC 6238 §A T=59 → 94287082" {
  out="$(printf '%s' "${RFC_SECRET}" | TOTP_TIME_T=59 TOTP_DIGITS=8 node "${TOTP_SCRIPT}")"
  [ "${out}" = "94287082" ] || fail "expected 94287082, got ${out}"
}

@test "totp.mjs (4-ii): RFC 6238 §A T=1111111109 → 07081804" {
  out="$(printf '%s' "${RFC_SECRET}" | TOTP_TIME_T=1111111109 TOTP_DIGITS=8 node "${TOTP_SCRIPT}")"
  [ "${out}" = "07081804" ] || fail "expected 07081804, got ${out}"
}

@test "totp.mjs (4-ii): RFC 6238 §A T=1111111111 → 14050471" {
  out="$(printf '%s' "${RFC_SECRET}" | TOTP_TIME_T=1111111111 TOTP_DIGITS=8 node "${TOTP_SCRIPT}")"
  [ "${out}" = "14050471" ] || fail "expected 14050471, got ${out}"
}

@test "totp.mjs (4-ii): RFC 6238 §A T=1234567890 → 89005924" {
  out="$(printf '%s' "${RFC_SECRET}" | TOTP_TIME_T=1234567890 TOTP_DIGITS=8 node "${TOTP_SCRIPT}")"
  [ "${out}" = "89005924" ] || fail "expected 89005924, got ${out}"
}

@test "totp.mjs (4-ii): RFC 6238 §A T=2000000000 → 69279037" {
  out="$(printf '%s' "${RFC_SECRET}" | TOTP_TIME_T=2000000000 TOTP_DIGITS=8 node "${TOTP_SCRIPT}")"
  [ "${out}" = "69279037" ] || fail "expected 69279037, got ${out}"
}

@test "totp.mjs (4-ii): default 6 digits — code is 6 chars long" {
  out="$(printf '%s' "${RFC_SECRET}" | TOTP_TIME_T=1234567890 node "${TOTP_SCRIPT}")"
  [ "${#out}" = "6" ] || fail "expected 6 chars, got ${#out} (${out})"
}

@test "totp.mjs (4-ii): empty stdin → exit 2" {
  run bash -c "printf '' | node '${TOTP_SCRIPT}'"
  [ "${status}" = "2" ] || fail "expected exit 2 for empty secret, got ${status}"
}

@test "totp.mjs (4-ii): invalid base32 char → exit 1" {
  run bash -c "printf 'NOTBASE32!!' | node '${TOTP_SCRIPT}'"
  [ "${status}" = "1" ] || fail "expected exit 1 for bad base32, got ${status}"
}
