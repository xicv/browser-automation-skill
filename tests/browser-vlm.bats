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

@test "browser-vlm start: port already bound by another process → EXIT_PREFLIGHT_FAILED" {
  # Bind a port with a tiny Python http server; cmd_start must refuse to spawn
  # rather than silently fail-bind and let bench talk to whoever's already
  # there (the port-collision bug the bench surfaced).
  port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 -u - <<EOF &
import http.server, socketserver, time, threading
srv = socketserver.TCPServer(("127.0.0.1", ${port}), http.server.BaseHTTPRequestHandler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(15)
srv.shutdown()
EOF
  squatter_pid=$!
  # Wait for the squatter to bind.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  # Use a no-op stub so cmd_start gets PAST the tool-missing guard and hits
  # the port check.
  no_op_stub="$(mktemp)"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "${no_op_stub}"
  chmod +x "${no_op_stub}"
  BROWSER_SKILL_VLM_PORT="${port}" \
  LLAMA_SERVER_BIN="${no_op_stub}" \
    run bash "${SCRIPTS_DIR}/browser-vlm.sh" start
  kill "${squatter_pid}" 2>/dev/null || true
  wait "${squatter_pid}" 2>/dev/null || true
  rm -f "${no_op_stub}"
  assert_status "${EXIT_PREFLIGHT_FAILED}"
  assert_output_contains "still bound"
}

@test "browser-vlm bench: regression — bench-model status is 'ok'|'partial'|'fail' (NOT embedded JSON)" {
  # The earlier cmd_bench bug captured _run_smoke_battery's stdout (which IS
  # the smoke NDJSON) into the status field, producing multi-line garbage.
  # Run against a tiny mock llama-server so we exercise the real code path.
  port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 -u - <<EOF &
import http.server, socketserver, json, threading, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
            self.wfile.write(json.dumps({"status":"ok"}).encode())
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        body_len = int(self.headers.get("Content-Length",0))
        self.rfile.read(body_len)
        self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
        self.wfile.write(json.dumps({
            "choices":[{"message":{"content":"hi"}}],
            "timings":{"prompt_per_second":50,"predicted_per_second":40}
        }).encode())
    def log_message(self,*a): pass
srv = socketserver.TCPServer(("127.0.0.1", ${port}), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(30)
srv.shutdown()
EOF
  fake_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sfm 1 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  # Need a real (no-op) llama-server binary on PATH for cmd_start to bypass
  # the EXIT_TOOL_MISSING guard. We use /bin/true wrapped — it'll spawn,
  # write to log, and "succeed". The bench's /health poll then talks to
  # the mock server above instead.
  no_op_stub="$(mktemp)"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "${no_op_stub}"
  chmod +x "${no_op_stub}"
  # Override the launch so bench doesn't actually load a real model.
  BROWSER_SKILL_VLM_PORT="${port}" \
  BROWSER_SKILL_VLM_HOST="127.0.0.1" \
  LLAMA_SERVER_BIN="${no_op_stub}" \
    run bash "${SCRIPTS_DIR}/browser-vlm.sh" bench --max-wait-s 6 "MockVendor/MockModel:Q1"
  kill "${fake_pid}" 2>/dev/null || true
  wait "${fake_pid}" 2>/dev/null || true
  rm -f "${no_op_stub}"
  # The bench may exit 1 because some smokes don't "hit" the mocked completion,
  # but the per-model line MUST be parseable JSON and status MUST be one of
  # ok / partial / fail / timeout.
  local model_line
  model_line="$(printf '%s\n' "${lines[@]}" | grep -E '"event":"bench-model"' | head -1)"
  [ -n "${model_line}" ] || fail "no bench-model event emitted; output: ${output}"
  # Must be one line of valid JSON.
  printf '%s' "${model_line}" | jq -e '.event == "bench-model"' >/dev/null \
    || fail "bench-model line is not single-line valid JSON: ${model_line}"
  # Status MUST be one of the known enum values, NOT embedded JSON garbage.
  local status_field
  status_field="$(printf '%s' "${model_line}" | jq -r '.status')"
  case "${status_field}" in
    ok|partial|fail|timeout|start-failed) : ;;
    *) fail "status must be ok|partial|fail|timeout|start-failed; got '${status_field}'" ;;
  esac
}
