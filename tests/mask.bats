load helpers

setup() {
  setup_temp_home
  init_paths
}
teardown() { teardown_temp_home; }

run_mask() {
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/mask.sh'
    mask_string \"\$@\"
  " _ "$@"
}

@test "mask.sh: file exists and is readable" {
  [ -f "${LIB_DIR}/mask.sh" ] || fail "lib file missing"
  [ -r "${LIB_DIR}/mask.sh" ] || fail "lib not readable"
}

@test "mask.sh: standard 11-char string with defaults (1 first, 1 last)" {
  out="$(run_mask "password123")"
  [ "${out}" = "p*********3" ] || fail "expected 'p*********3', got '${out}'"
}

@test "mask.sh: empty string → empty output" {
  out="$(run_mask "")"
  [ "${out}" = "" ] || fail "expected empty, got '${out}'"
}

@test "mask.sh: 1-char string → single star (no leak)" {
  out="$(run_mask "x")"
  [ "${out}" = "*" ] || fail "expected '*', got '${out}'"
}

@test "mask.sh: 2-char string → all stars (no leak — len <= SHOW_FIRST + SHOW_LAST)" {
  out="$(run_mask "ab")"
  [ "${out}" = "**" ] || fail "expected '**', got '${out}'"
}

@test "mask.sh: 3-char string → 1 first + 1 star + 1 last" {
  out="$(run_mask "abc")"
  [ "${out}" = "a*c" ] || fail "expected 'a*c', got '${out}'"
}

@test "mask.sh: custom SHOW_FIRST=2 SHOW_LAST=2" {
  out="$(run_mask "abcdefghij" 2 2)"
  [ "${out}" = "ab******ij" ] || fail "expected 'ab******ij', got '${out}'"
}

@test "mask.sh: very-long string (200 chars) → middle stars capped at 80" {
  long="$(printf 'a%.0s' {1..198})bz"  # 200 chars total ('a'×198 + 'b' + 'z')
  out="$(run_mask "${long}")"
  # Format: first(1) + stars(<=80) + last(1) = at most 82 chars
  len=${#out}
  [ "${len}" -le 82 ] || fail "expected masked output <= 82 chars, got ${len}"
  case "${out}" in
    a*z) ;;
    *) fail "expected output to start 'a' and end 'z', got '${out}'" ;;
  esac
}
