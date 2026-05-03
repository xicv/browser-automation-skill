load helpers

setup() {
  setup_temp_home
  init_paths
}
teardown() {
  teardown_temp_home
}

run_select() {
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/secret_backend_select.sh'
    detect_backend
  "
}

@test "secret_backend_select.sh: file exists and is readable" {
  [ -f "${LIB_DIR}/secret_backend_select.sh" ] || fail "lib file missing"
  [ -r "${LIB_DIR}/secret_backend_select.sh" ] || fail "lib not readable"
}

@test "secret_backend_select.sh: BROWSER_SKILL_FORCE_BACKEND override is honored" {
  out="$(BROWSER_SKILL_FORCE_BACKEND=plaintext run_select)"
  [ "${out}" = "plaintext" ] || fail "expected plaintext, got ${out}"
  out="$(BROWSER_SKILL_FORCE_BACKEND=keychain run_select)"
  [ "${out}" = "keychain" ] || fail "expected keychain, got ${out}"
  out="$(BROWSER_SKILL_FORCE_BACKEND=libsecret run_select)"
  [ "${out}" = "libsecret" ] || fail "expected libsecret, got ${out}"
}

@test "secret_backend_select.sh: BROWSER_SKILL_FORCE_BACKEND rejects invalid values (falls through to auto-detect)" {
  # An invalid override should be ignored, not cause an error — auto-detect
  # picks something based on OS. Don't pin the value (depends on host OS), just
  # require the result is a valid backend name.
  out="$(BROWSER_SKILL_FORCE_BACKEND=made-up-vault run_select)"
  case "${out}" in
    keychain|libsecret|plaintext) ;;
    *) fail "auto-detect returned invalid backend '${out}' for invalid override" ;;
  esac
}

@test "secret_backend_select.sh: Darwin + reachable security stub → keychain" {
  out="$(KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security" run_select_with_uname Darwin)"
  [ "${out}" = "keychain" ] || fail "expected keychain on Darwin with stub, got ${out}"
}

@test "secret_backend_select.sh: Darwin + missing security bin → plaintext" {
  out="$(KEYCHAIN_SECURITY_BIN="/nonexistent/security-bin-${RANDOM}" run_select_with_uname Darwin)"
  [ "${out}" = "plaintext" ] || fail "expected plaintext on Darwin without security, got ${out}"
}

@test "secret_backend_select.sh: Linux + reachable secret-tool stub → libsecret" {
  out="$(LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool" run_select_with_uname Linux)"
  [ "${out}" = "libsecret" ] || fail "expected libsecret on Linux with stub, got ${out}"
}

@test "secret_backend_select.sh: Linux + missing secret-tool → plaintext" {
  out="$(LIBSECRET_TOOL_BIN="/nonexistent/secret-tool-${RANDOM}" run_select_with_uname Linux)"
  [ "${out}" = "plaintext" ] || fail "expected plaintext on Linux without secret-tool, got ${out}"
}

@test "secret_backend_select.sh: unknown OS → plaintext" {
  out="$(run_select_with_uname FreeBSD)"
  [ "${out}" = "plaintext" ] || fail "expected plaintext on FreeBSD, got ${out}"
}

# Helper: simulate a different uname -s by intercepting `uname` in the lib's
# environment via a tiny shim binary in PATH.
run_select_with_uname() {
  local fake_os="$1"
  local shim_dir="${TEST_HOME}/uname-shim"
  mkdir -p "${shim_dir}"
  cat > "${shim_dir}/uname" <<EOF
#!/usr/bin/env bash
# Test shim: only intercept "-s" form; pass through everything else.
if [ "\${1:-}" = "-s" ]; then
  printf '%s\n' "${fake_os}"
else
  exec /usr/bin/uname "\$@"
fi
EOF
  chmod +x "${shim_dir}/uname"
  PATH="${shim_dir}:${PATH}" bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/secret_backend_select.sh'
    detect_backend
  "
}
