load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

# --- Phase 14: scripts/browser-vlm.sh lifecycle wrapper -----------------

@test "browser-vlm: --help prints usage including all four subcommands" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" --help
  assert_status 0
  assert_output_contains "start"
  assert_output_contains "stop"
  assert_output_contains "status"
  assert_output_contains "smoke"
  assert_output_contains "8192"        # lean ctx-size
  assert_output_contains "Qwen3-VL"    # default model
}

@test "browser-vlm: no args (default) prints help and exits 0" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh"
  assert_status 0
  assert_output_contains "Usage:"
}

@test "browser-vlm: unknown subcommand exits EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" bogus-subcmd
  assert_status "${EXIT_USAGE_ERROR}"
  assert_output_contains "unknown subcommand"
}

@test "browser-vlm start --dry-run: prints lean argv + exits 0; no process spawned; no pidfile written" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" start --dry-run
  assert_status 0
  # All lean flags must appear verbatim in the printed command.
  assert_output_contains "llama-server"
  assert_output_contains "--ctx-size"
  assert_output_contains "8192"
  assert_output_contains "--parallel"
  assert_output_contains "--threads"
  assert_output_contains "--threads-batch"
  assert_output_contains "--cache-ram"
  assert_output_contains "--n-gpu-layers"
  assert_output_contains "Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M"
  [ ! -f "${BROWSER_SKILL_HOME}/vlm.pid" ] || fail "pidfile must NOT be written on --dry-run"
}

@test "browser-vlm start --dry-run: BROWSER_SKILL_VLM_* env overrides flow into the command" {
  BROWSER_SKILL_VLM_PORT=9999 \
  BROWSER_SKILL_VLM_THREADS=2 \
  BROWSER_SKILL_VLM_MODEL="my/CustomModel:Q5" \
    run bash "${SCRIPTS_DIR}/browser-vlm.sh" start --dry-run
  assert_status 0
  assert_output_contains "9999"
  assert_output_contains "my/CustomModel:Q5"
  # --threads value follows the flag; assert the pair appears in order.
  case "${output}" in
    *"--threads 2 "*) : ;;
    *) fail "expected '--threads 2' in output; got: ${output}" ;;
  esac
}

@test "browser-vlm stop: no-op success when no pidfile present" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" stop
  assert_status 0
  assert_output_contains "not running"
}

@test "browser-vlm stop: no-op when pidfile points at dead pid + cleans up pidfile" {
  # Seed a pidfile with a definitely-dead pid (pid 1 is init; impossible to be ours).
  # Use a very-high pid that can't be alive (kill -0 returns 1).
  printf '999999\n' > "${BROWSER_SKILL_HOME}/vlm.pid"
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" stop
  assert_status 0
  assert_output_contains "not running"
  [ ! -f "${BROWSER_SKILL_HOME}/vlm.pid" ] || fail "stale pidfile should be removed"
}

@test "browser-vlm status: 'not running' returns exit 11 (EXIT_EMPTY_RESULT) when no server" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" status
  assert_status 11
  assert_output_contains "not running"
}

@test "browser-vlm status: pid alive but /health unreachable → warn + exit 11" {
  # Seed pidfile with our own shell's PID (definitely alive).
  printf '%d\n' "$$" > "${BROWSER_SKILL_HOME}/vlm.pid"
  # Pick an unused high-numbered port so /health curl will fail-fast.
  BROWSER_SKILL_VLM_PORT=59999 run bash "${SCRIPTS_DIR}/browser-vlm.sh" status
  assert_status 11
  assert_output_contains "unreachable"
}

@test "browser-vlm smoke: preflight rejects when server not reachable" {
  BROWSER_SKILL_VLM_PORT=59999 \
    run bash "${SCRIPTS_DIR}/browser-vlm.sh" smoke
  assert_status "${EXIT_PREFLIGHT_FAILED}"
  assert_output_contains "vlm not reachable"
}

@test "browser-vlm start: llama-server missing → EXIT_TOOL_MISSING" {
  # Mask llama-server out of PATH for the duration of this test.
  LLAMA_SERVER_BIN=/nonexistent/llama-server \
    run bash "${SCRIPTS_DIR}/browser-vlm.sh" start
  assert_status "${EXIT_TOOL_MISSING}"
  assert_output_contains "not on PATH"
}

# --- Phase 14 (E3): vlm bench command ----------------------------------

@test "browser-vlm bench --help: shows usage including default model list" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" bench --help
  assert_status 0
  assert_output_contains "Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M"
  assert_output_contains "Qwen/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M"
  assert_output_contains "4-smoke battery"
}

@test "browser-vlm bench --dry-run: emits bench-start + bench-done events with default models" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" bench --dry-run
  assert_status 0
  # First line should be bench-start with a models array of 3.
  local first
  first="$(printf '%s\n' "${lines[@]}" | grep -E '"event":"bench-start"' | head -1)"
  [ -n "${first}" ] || fail "missing bench-start event; output: ${output}"
  printf '%s' "${first}" | jq -e '.models | length == 3' >/dev/null \
    || fail "default model list should have 3 entries; got: ${first}"
  printf '%s' "${first}" | jq -e '.models[0] | test("Qwen3-VL")' >/dev/null \
    || fail "default models should be Qwen3-VL family; got: ${first}"
  # Final bench-done should report dry_run:true.
  local last
  last="$(printf '%s\n' "${lines[@]}" | grep -E '"event":"bench-done"' | tail -1)"
  printf '%s' "${last}" | jq -e '.dry_run == true and .total_models == 3' >/dev/null \
    || fail "bench-done should show dry_run:true; got: ${last}"
}

@test "browser-vlm bench --dry-run: positional models override the default list" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" bench --dry-run \
    "Vendor/ModelA:Q1" "Vendor/ModelB:Q2"
  assert_status 0
  local first
  first="$(printf '%s\n' "${lines[@]}" | grep -E '"event":"bench-start"' | head -1)"
  printf '%s' "${first}" \
    | jq -e '.models == ["Vendor/ModelA:Q1","Vendor/ModelB:Q2"]' >/dev/null \
    || fail "expected positional models to win; got: ${first}"
}

@test "browser-vlm bench: llama-server missing → EXIT_TOOL_MISSING (only when not --dry-run)" {
  LLAMA_SERVER_BIN=/nonexistent/llama-server \
    run bash "${SCRIPTS_DIR}/browser-vlm.sh" bench "Vendor/Tiny:Q1"
  assert_status "${EXIT_TOOL_MISSING}"
  assert_output_contains "not on PATH"
}

@test "browser-vlm bench: unknown flag → EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-vlm.sh" bench --bogus-flag
  assert_status "${EXIT_USAGE_ERROR}"
  assert_output_contains "unknown flag"
}
