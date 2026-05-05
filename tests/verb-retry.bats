load helpers

# Phase 5 part 3-ii: unit tests for invoke_with_retry helper.
#
# Tests mock tool_<verb> + _can_auto_relogin + _silent_relogin in the test
# scope so the harness verifies retry control flow without spawning real
# adapters or login flows. End-to-end coverage (a verb hitting a real adapter
# that returns 22, triggering real login --auto, retrying) is out of scope
# for the helper PR — comes when the helper wires into all verbs.

setup() {
  setup_temp_home
  COUNTER="$(mktemp "${TEST_HOME}/counter.XXXXXX")"
  export COUNTER
}
teardown() {
  rm -f "${COUNTER:-}"
  teardown_temp_home
}

# Helper: source verb_helpers.sh inside the bash subshell so test-local
# function overrides take effect. Using `bats run bash -c ...` keeps each
# test isolated in its own subshell.
run_invoke_with_retry() {
  local script="$1"
  # NB: no `set -e` inside — invoke_with_retry returning non-zero is a normal
  # path the test needs to observe. errexit would kill the wrapper before
  # printf could record rc.
  run bash -c "
    export COUNTER='${COUNTER}'
    source '${LIB_DIR}/common.sh'
    init_paths
    source '${LIB_DIR}/router.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    # NB: mock-fn definitions go AFTER sourcing verb_helpers.sh so they
    # override the helpers' real implementations (function redefinition).
    ${script}
    out=\"\$(invoke_with_retry test arg1 arg2)\"
    rc=\$?
    printf 'out=%s\nrc=%s\n' \"\${out}\" \"\${rc}\"
  "
}

@test "invoke_with_retry: tool returning 0 → no retry, output unchanged" {
  run_invoke_with_retry '
    tool_test() { printf "first-success"; return 0; }
  '
  assert_status 0
  assert_output_contains "out=first-success"
  assert_output_contains "rc=0"
}

@test "invoke_with_retry: tool returning rc != 22 (e.g. 30) → no retry, propagated" {
  run_invoke_with_retry '
    tool_test() { printf "network-fail"; return 30; }
  '
  assert_status 0
  assert_output_contains "out=network-fail"
  assert_output_contains "rc=30"
}

@test "invoke_with_retry: tool returning 22 + no auto-relogin → no retry, original error propagated" {
  run_invoke_with_retry '
    tool_test() { printf "session-expired"; return 22; }
    _can_auto_relogin() { return 1; }
  '
  assert_status 0
  assert_output_contains "out=session-expired"
  assert_output_contains "rc=22"
}

@test "invoke_with_retry: tool returning 22 + auto-relogin OK + retry succeeds → final rc=0, output from retry" {
  run_invoke_with_retry "
    tool_test() {
      local n; n=\"\$(cat \"\${COUNTER}\")\"; echo \$((n+1)) > \"\${COUNTER}\"
      if [ \"\${n}\" = '0' ]; then printf 'first-fail'; return 22; fi
      printf 'second-success'; return 0
    }
    _can_auto_relogin() { return 0; }
    _silent_relogin() { return 0; }
    resolve_session_storage_state() { return 0; }
  "
  echo 0 > "${COUNTER}"
  run_invoke_with_retry "
    tool_test() {
      local n; n=\"\$(cat \"\${COUNTER}\")\"; echo \$((n+1)) > \"\${COUNTER}\"
      if [ \"\${n}\" = '0' ]; then printf 'first-fail'; return 22; fi
      printf 'second-success'; return 0
    }
    _can_auto_relogin() { return 0; }
    _silent_relogin() { return 0; }
    resolve_session_storage_state() { return 0; }
  "
  assert_status 0
  assert_output_contains "out=second-success"
  assert_output_contains "rc=0"
  [ "$(cat "${COUNTER}")" = "2" ] || fail "expected tool_test called twice; counter=$(cat "${COUNTER}")"
}

@test "invoke_with_retry: tool returning 22 + relogin fails → no retry, original error propagated" {
  run_invoke_with_retry '
    tool_test() { printf "expired-orig"; return 22; }
    _can_auto_relogin() { return 0; }
    _silent_relogin() { return 1; }
    resolve_session_storage_state() { return 0; }
  '
  assert_status 0
  assert_output_contains "out=expired-orig"
  assert_output_contains "rc=22"
}

@test "invoke_with_retry: tool returning 22 twice (retry also fails 22) → final rc=22 (no double-retry)" {
  echo 0 > "${COUNTER}"
  run_invoke_with_retry "
    tool_test() {
      local n; n=\"\$(cat \"\${COUNTER}\")\"; echo \$((n+1)) > \"\${COUNTER}\"
      printf 'still-expired-%s' \"\${n}\"; return 22
    }
    _can_auto_relogin() { return 0; }
    _silent_relogin() { return 0; }
    resolve_session_storage_state() { return 0; }
  "
  assert_status 0
  assert_output_contains "out=still-expired-1"
  assert_output_contains "rc=22"
  [ "$(cat "${COUNTER}")" = "2" ] || fail "expected tool_test called twice (no triple-call); counter=$(cat "${COUNTER}")"
}
