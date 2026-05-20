load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  PROBE="${LIB_DIR}/visual-rescue-default.sh"
  export PROBE
}
teardown() {
  teardown_temp_home
}

# Start a tiny Python httpd on an ephemeral port that fakes the OpenAI-compat
# /health + /v1/chat/completions endpoints. $1 = "yes" | "no" | "down".
_start_mock_vlm() {
  local mode="$1"
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  export MOCK_VLM_PORT="${port}"
  if [ "${mode}" = "down" ]; then
    # No server. Just return; probe will fail health check.
    return 0
  fi
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
        n = int(self.headers.get("Content-Length",0)); self.rfile.read(n)
        self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
        completion = "${mode}"
        self.wfile.write(json.dumps({
            "choices":[{"message":{"content":completion}}]
        }).encode())
    def log_message(self,*a): pass
srv = socketserver.TCPServer(("127.0.0.1",${port}),H)
threading.Thread(target=srv.serve_forever,daemon=True).start()
time.sleep(30)
srv.shutdown()
EOF
  export MOCK_VLM_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sfm 1 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
}

_stop_mock_vlm() {
  if [ -n "${MOCK_VLM_PID:-}" ]; then
    kill "${MOCK_VLM_PID}" 2>/dev/null || true
    wait "${MOCK_VLM_PID}" 2>/dev/null || true
    unset MOCK_VLM_PID
  fi
}

# Make a stub browser-snapshot.sh that emits a fake summary line; override
# BROWSER_SKILL_SCRIPTS_DIR so the probe picks it up.
_stub_snapshot_script() {
  local payload="$1"
  local dir; dir="$(mktemp -d)"
  cat > "${dir}/browser-snapshot.sh" <<EOF
#!/usr/bin/env bash
# Stub for visual-rescue-default tests; ignores args, prints fake summary.
printf '%s\n' '${payload}'
EOF
  chmod +x "${dir}/browser-snapshot.sh"
  printf '%s' "${dir}"
}

# --- Tests --------------------------------------------------------------

@test "visual-rescue-default: missing args → exit 2 + stdout 'no'" {
  run bash "${PROBE}"
  assert_status 2
  assert_output_contains "no"
}

@test "visual-rescue-default: VLM unreachable → exit 1 + stdout 'no'" {
  # Pick an unused high port so curl fails fast.
  BROWSER_SKILL_VLM_PORT=59999 \
    run bash "${PROBE}" myapp "click delete" "button.delete"
  assert_status 1
  assert_output_contains "no"
}

@test "visual-rescue-default: VLM up + snapshot says yes → stdout 'yes' exit 0" {
  _start_mock_vlm yes
  stub_dir="$(_stub_snapshot_script '{"verb":"snapshot","status":"ok","url":"https://example.com","title":"x"}')"
  BROWSER_SKILL_VLM_PORT="${MOCK_VLM_PORT}" \
  BROWSER_SKILL_SCRIPTS_DIR="${stub_dir}" \
    run bash "${PROBE}" myapp "click delete" "button.delete"
  _stop_mock_vlm
  rm -rf "${stub_dir}"
  assert_status 0
  printf '%s' "${output}" | grep -qE '^yes$' \
    || fail "expected stdout 'yes'; got: ${output}"
}

@test "visual-rescue-default: VLM up + says no → stdout 'no' exit 0" {
  _start_mock_vlm no
  stub_dir="$(_stub_snapshot_script '{"verb":"snapshot","status":"ok","url":"https://example.com","title":"x"}')"
  BROWSER_SKILL_VLM_PORT="${MOCK_VLM_PORT}" \
  BROWSER_SKILL_SCRIPTS_DIR="${stub_dir}" \
    run bash "${PROBE}" myapp "click delete" "button.delete"
  _stop_mock_vlm
  rm -rf "${stub_dir}"
  assert_status 0
  printf '%s' "${output}" | grep -qE '^no$' \
    || fail "expected stdout 'no'; got: ${output}"
}

@test "visual-rescue-default: snapshot script missing → exit 1 'no'" {
  _start_mock_vlm yes
  BROWSER_SKILL_VLM_PORT="${MOCK_VLM_PORT}" \
  BROWSER_SKILL_SCRIPTS_DIR=/nonexistent/path \
    run bash "${PROBE}" myapp "click delete" "button.delete"
  _stop_mock_vlm
  assert_status 1
  assert_output_contains "no"
}

@test "visual-rescue-default: snapshot returns empty → exit 1 'no'" {
  _start_mock_vlm yes
  stub_dir="$(_stub_snapshot_script '')"
  BROWSER_SKILL_VLM_PORT="${MOCK_VLM_PORT}" \
  BROWSER_SKILL_SCRIPTS_DIR="${stub_dir}" \
    run bash "${PROBE}" myapp "click delete" "button.delete"
  _stop_mock_vlm
  rm -rf "${stub_dir}"
  assert_status 1
  assert_output_contains "no"
}

@test "visual-rescue-default: integration via browser-do.sh + this probe → cache rescued" {
  # End-to-end: real browser-do invocation with the canonical default probe
  # as BROWSER_SKILL_VISUAL_RESCUE_CMD. Mock VLM returns "yes" so probe
  # confirms; browser-do should treat cache as rescued.
  _start_mock_vlm yes
  # Stub the snapshot script (browser-do uses scripts/lib but the probe needs
  # the real scripts dir for browser-snapshot.sh — override via env).
  stub_dir="$(_stub_snapshot_script '{"verb":"snapshot","status":"ok","url":"https://app/devices/1","title":"x"}')"
  # Register + seed cache exactly like browser-do dispatch-fail tests.
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name app --url https://app/ >/dev/null
  mkdir -p "${BROWSER_SKILL_HOME}/memory/app/archetypes"
  cat > "${BROWSER_SKILL_HOME}/memory/app/patterns.json" <<EOF
{"patterns":[{"url_pattern":"/devices/:id","archetype_id":"devices-id"}],"version":1}
EOF
  cat > "${BROWSER_SKILL_HOME}/memory/app/archetypes/devices-id.json" <<EOF
{"archetype_id":"devices-id","url_pattern":"/devices/:id","interactions":[
  {"intent":"click thing","selector":"button.thing","verb":"click","fail_count":0,"disabled":false}
]}
EOF
  # Mock dispatcher always exits 11 (selector miss).
  override="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 11\n' > "${override}"
  chmod +x "${override}"
  BROWSER_DO_DISPATCH_OVERRIDE="${override}" \
  BROWSER_SKILL_VISION_FALLBACK=1 \
  BROWSER_SKILL_VISUAL_RESCUE_CMD="${PROBE}" \
  BROWSER_SKILL_VLM_PORT="${MOCK_VLM_PORT}" \
  BROWSER_SKILL_SCRIPTS_DIR="${stub_dir}" \
    run bash "${SCRIPTS_DIR}/browser-do.sh" \
      --site app --verb click --intent "click thing" \
      --url 'https://app.example.com/devices/123'
  _stop_mock_vlm
  rm -rf "${stub_dir}" "${override}"
  assert_status 0
  echo "${output}" | jq -rs 'map(select(._kind == "visual_rescue")) | length' \
    | grep -qE '^[1-9]' \
    || fail "expected visual_rescue stream line; got: ${output}"
}
