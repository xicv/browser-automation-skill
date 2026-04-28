# tests/helpers.bash
# Common bats helpers. `load helpers` from any *.bats picks this up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
SCRIPTS_DIR="${REPO_ROOT}/scripts"

# Per-test isolated home. Set in setup(); torn down in teardown().
setup_temp_home() {
  TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/browser-skill-test.XXXXXX")"
  export BROWSER_SKILL_HOME="${TEST_HOME}/.browser-skill"
  export HOME="${TEST_HOME}"
}

teardown_temp_home() {
  if [ -n "${TEST_HOME:-}" ] && [ -d "${TEST_HOME}" ]; then
    rm -rf "${TEST_HOME}"
  fi
}

# Assert that a string is present in $output (bats sets $output on `run`).
assert_output_contains() {
  local needle="$1"
  if ! printf '%s' "${output}" | grep -qF -- "${needle}"; then
    printf 'expected output to contain:\n  %s\n--- actual output ---\n%s\n' "${needle}" "${output}" >&2
    return 1
  fi
}

assert_output_not_contains() {
  local needle="$1"
  if printf '%s' "${output}" | grep -qF -- "${needle}"; then
    printf 'expected output NOT to contain:\n  %s\n--- actual output ---\n%s\n' "${needle}" "${output}" >&2
    return 1
  fi
}

# Assert exit status (mirrors bats-assert's assert_failure but no extra dep).
assert_status() {
  local expected="$1"
  if [ "${status}" -ne "${expected}" ]; then
    printf 'expected status %d, got %d\n--- output ---\n%s\n' "${expected}" "${status}" "${output}" >&2
    return 1
  fi
}

# Portable fail() — bats-core ships one in newer versions, but not all distros.
# Define our own so tests run on Ubuntu's older bats package too.
if ! declare -F fail >/dev/null 2>&1; then
  fail() {
    printf 'fail: %s\n' "$*" >&2
    return 1
  }
fi
