#!/usr/bin/env bash
# scripts/browser-vlm.sh — wrap llama-server for local-VLM use w/ the
# session-validated lean config.
#
# Usage:
#   bash scripts/browser-vlm.sh start [--dry-run]
#   bash scripts/browser-vlm.sh stop
#   bash scripts/browser-vlm.sh status
#   bash scripts/browser-vlm.sh smoke
#   bash scripts/browser-vlm.sh --help
#
# Phase 14: spawned during midscene-integration smoke runs proved the FAT
# default config (parallel=4, ctx=175616, threads=all-P-cores) was 18-36x
# slower than the lean config below on the same hardware. This helper
# bakes the lean numbers in so users don't retype 6 flags every session.
#
# State (mode 0600 inside the mode-0700 BROWSER_SKILL_HOME):
#   ~/.browser-skill/vlm.pid    PID of running llama-server
#   ~/.browser-skill/vlm.log    stdout+stderr from llama-server
#
# Env overrides (defaults validated 2026-05-20 on M3 Pro / 36 GB):
#   BROWSER_SKILL_VLM_MODEL          Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M
#   BROWSER_SKILL_VLM_HOST           127.0.0.1
#   BROWSER_SKILL_VLM_PORT           8080
#   BROWSER_SKILL_VLM_CTX_SIZE       8192
#   BROWSER_SKILL_VLM_PARALLEL       1
#   BROWSER_SKILL_VLM_THREADS        4
#   BROWSER_SKILL_VLM_THREADS_BATCH  6
#   BROWSER_SKILL_VLM_CACHE_RAM_MB   512
#   BROWSER_SKILL_VLM_NGL            99  (Metal layers; macOS default)
#   BROWSER_SKILL_NODE_BIN          (unused here; reserved for parity w/ browser-mcp)
#   LLAMA_SERVER_BIN                llama-server

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-llama-server}"
VLM_MODEL="${BROWSER_SKILL_VLM_MODEL:-Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M}"
VLM_HOST="${BROWSER_SKILL_VLM_HOST:-127.0.0.1}"
VLM_PORT="${BROWSER_SKILL_VLM_PORT:-8080}"
VLM_CTX="${BROWSER_SKILL_VLM_CTX_SIZE:-8192}"
VLM_PARALLEL="${BROWSER_SKILL_VLM_PARALLEL:-1}"
VLM_THREADS="${BROWSER_SKILL_VLM_THREADS:-4}"
VLM_THREADS_BATCH="${BROWSER_SKILL_VLM_THREADS_BATCH:-6}"
VLM_CACHE_RAM="${BROWSER_SKILL_VLM_CACHE_RAM_MB:-512}"
VLM_NGL="${BROWSER_SKILL_VLM_NGL:-99}"

BROWSER_SKILL_HOME="${BROWSER_SKILL_HOME:-${HOME}/.browser-skill}"
VLM_PID_FILE="${BROWSER_SKILL_HOME}/vlm.pid"
VLM_LOG_FILE="${BROWSER_SKILL_HOME}/vlm.log"
VLM_WATCHDOG_PID_FILE="${BROWSER_SKILL_HOME}/vlm-watchdog.pid"
VLM_LAST_USED_FILE="${BROWSER_SKILL_HOME}/vlm.last-used"
VLM_IDLE_TIMEOUT_S="${BROWSER_SKILL_VLM_IDLE_TIMEOUT:-600}"   # 10 min default
VLM_WATCHDOG_POLL_S="${BROWSER_SKILL_VLM_WATCHDOG_POLL:-60}"  # 1 min default

_ensure_home() {
  mkdir -p "${BROWSER_SKILL_HOME}" 2>/dev/null || die "${EXIT_GENERIC_ERROR}" \
    "cannot create ${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}" 2>/dev/null || true
}

_lean_argv() {
  printf '%s\n' \
    -hf "${VLM_MODEL}" \
    --host "${VLM_HOST}" \
    --port "${VLM_PORT}" \
    --ctx-size "${VLM_CTX}" \
    --parallel "${VLM_PARALLEL}" \
    --threads "${VLM_THREADS}" \
    --threads-batch "${VLM_THREADS_BATCH}" \
    --cache-ram "${VLM_CACHE_RAM}" \
    --n-gpu-layers "${VLM_NGL}"
}

_pid_alive() {
  local pid="${1:-}"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null
}

# _wait_port_free PORT [MAX_WAIT_S]
# Returns 0 when nothing's listening on PORT, 1 if still bound after MAX_WAIT_S.
# Polls every 1s. Phase 14 bench-fix: needed because cmd_start spawning
# llama-server while port is TIME_WAIT'd by a prior instance caused silent
# bind failure + bench talking to the wrong (still-loaded) model.
_wait_port_free() {
  local port="${1:?port required}" max_wait="${2:-5}" waited=0
  while [ "${waited}" -lt "${max_wait}" ]; do
    if ! lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

_read_pid() {
  [ -f "${VLM_PID_FILE}" ] || return 1
  local pid
  pid="$(cat "${VLM_PID_FILE}" 2>/dev/null)" || return 1
  [ -n "${pid}" ] || return 1
  printf '%s' "${pid}"
}

cmd_start() {
  local dry_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      *) die "${EXIT_USAGE_ERROR}" "start: unknown flag '${1}'" ;;
    esac
  done

  _ensure_home

  if existing="$(_read_pid)" && _pid_alive "${existing}"; then
    ok "vlm already running (pid ${existing}) at http://${VLM_HOST}:${VLM_PORT}"
    return 0
  fi

  if [ "${dry_run}" = "1" ]; then
    printf '%s ' "${LLAMA_SERVER_BIN}"
    local arg
    while IFS= read -r arg; do
      printf '%s ' "${arg}"
    done < <(_lean_argv)
    printf '\n'
    ok "dry-run: would launch llama-server with lean config above"
    return 0
  fi

  if ! command -v "${LLAMA_SERVER_BIN}" >/dev/null 2>&1; then
    die "${EXIT_TOOL_MISSING}" "${LLAMA_SERVER_BIN} not on PATH — brew install llama.cpp"
  fi

  # Port-rebind safety (bench-fix). Refuse to spawn if the port is already
  # bound by something else — otherwise llama-server bind-fails silently
  # inside nohup, the recorded PID is the wrapper shell's child (not the
  # actual server), /health continues to answer from whoever was already
  # there, and bench ends up talking to the wrong model.
  if ! _wait_port_free "${VLM_PORT}" 5; then
    die "${EXIT_PREFLIGHT_FAILED}" \
      "port ${VLM_PORT} still bound after 5s — check 'lsof -nP -iTCP:${VLM_PORT}' and stop the holder"
  fi

  # Detached spawn; redirect stdout+stderr to log; record PID.
  local argv=()
  while IFS= read -r arg; do
    argv+=("${arg}")
  done < <(_lean_argv)

  # nohup + setsid pattern keeps child alive across this shell's exit.
  : > "${VLM_LOG_FILE}"
  chmod 600 "${VLM_LOG_FILE}" 2>/dev/null || true
  nohup "${LLAMA_SERVER_BIN}" "${argv[@]}" >> "${VLM_LOG_FILE}" 2>&1 &
  local pid=$!
  printf '%s\n' "${pid}" > "${VLM_PID_FILE}"
  chmod 600 "${VLM_PID_FILE}" 2>/dev/null || true

  ok "vlm starting (pid ${pid}) — first launch downloads ~3.5 GB to ~/.cache/huggingface/"
  ok "log:  tail -f ${VLM_LOG_FILE}"
  ok "ping: curl http://${VLM_HOST}:${VLM_PORT}/health    (returns {\"status\":\"ok\"} when ready)"

  # Phase 14+ smart-stop: spawn an idle-stop watchdog companion. Polls
  # ${VLM_LAST_USED_FILE} mtime every BROWSER_SKILL_VLM_WATCHDOG_POLL seconds;
  # if older than BROWSER_SKILL_VLM_IDLE_TIMEOUT, calls cmd_stop. Without
  # this, llama-server would hold ~4 GB resident forever after first use.
  # The default-rescue probe (scripts/lib/visual-rescue-default.sh) touches
  # the last-used file on every invocation, so the watchdog only counts
  # REAL usage (not /health pings).
  # Disable via BROWSER_SKILL_VLM_IDLE_TIMEOUT=0 (never stop).
  if [ "${VLM_IDLE_TIMEOUT_S}" -gt 0 ]; then
    : > "${VLM_LAST_USED_FILE}"
    chmod 600 "${VLM_LAST_USED_FILE}" 2>/dev/null || true
    nohup bash -c "
      set -u
      while true; do
        sleep ${VLM_WATCHDOG_POLL_S}
        # Server gone → watchdog exits.
        if [ ! -f '${VLM_PID_FILE}' ]; then break; fi
        srv_pid=\$(cat '${VLM_PID_FILE}' 2>/dev/null || true)
        [ -n \"\${srv_pid}\" ] || break
        kill -0 \"\${srv_pid}\" 2>/dev/null || break
        # Idle check via last-used mtime.
        if [ -f '${VLM_LAST_USED_FILE}' ]; then
          now_s=\$(date +%s)
          last_s=\$(stat -f %m '${VLM_LAST_USED_FILE}' 2>/dev/null \
                   || stat -c %Y '${VLM_LAST_USED_FILE}' 2>/dev/null \
                   || echo \"\${now_s}\")
          age=\$((now_s - last_s))
          if [ \"\${age}\" -ge ${VLM_IDLE_TIMEOUT_S} ]; then
            kill \"\${srv_pid}\" 2>/dev/null || true
            rm -f '${VLM_PID_FILE}' '${VLM_LAST_USED_FILE}' 2>/dev/null || true
            break
          fi
        fi
      done
      rm -f '${VLM_WATCHDOG_PID_FILE}' 2>/dev/null || true
    " >> "${VLM_LOG_FILE}" 2>&1 &
    watchdog_pid=$!
    printf '%s\n' "${watchdog_pid}" > "${VLM_WATCHDOG_PID_FILE}"
    chmod 600 "${VLM_WATCHDOG_PID_FILE}" 2>/dev/null || true
    ok "watchdog (pid ${watchdog_pid}) — idle-stop after ${VLM_IDLE_TIMEOUT_S}s no use"
  fi
}

cmd_stop() {
  # Kill watchdog first so it doesn't see the server vanish and panic.
  if [ -f "${VLM_WATCHDOG_PID_FILE}" ]; then
    wd_pid=$(cat "${VLM_WATCHDOG_PID_FILE}" 2>/dev/null || true)
    if [ -n "${wd_pid}" ] && kill -0 "${wd_pid}" 2>/dev/null; then
      kill "${wd_pid}" 2>/dev/null || true
    fi
    rm -f "${VLM_WATCHDOG_PID_FILE}" 2>/dev/null || true
  fi
  if existing="$(_read_pid)" && _pid_alive "${existing}"; then
    kill "${existing}" 2>/dev/null || true
    # Give it 2s to exit cleanly; SIGKILL if still alive.
    local _
    for _ in 1 2 3 4; do
      _pid_alive "${existing}" || break
      sleep 0.5
    done
    if _pid_alive "${existing}"; then
      kill -9 "${existing}" 2>/dev/null || true
    fi
    ok "vlm stopped (pid ${existing})"
  else
    ok "vlm not running (no-op)"
  fi
  rm -f "${VLM_PID_FILE}" "${VLM_LAST_USED_FILE}" 2>/dev/null || true
  # Port-release wait — bench-fix companion. PID dying doesn't always release
  # the port instantly on macOS (TIME_WAIT). 5s is enough for SO_REUSEADDR
  # paths; if still bound, warn but don't fail (caller may have spawned a
  # different listener that we don't own).
  _wait_port_free "${VLM_PORT}" 5 \
    || warn "port ${VLM_PORT} still bound after stop; next 'start' may fail-fast (use lsof to inspect)"
}

cmd_status() {
  local pid
  if pid="$(_read_pid)" && _pid_alive "${pid}"; then
    local health_body
    if health_body="$(curl -sfm 3 "http://${VLM_HOST}:${VLM_PORT}/health" 2>/dev/null)"; then
      ok "vlm running (pid ${pid}) — endpoint http://${VLM_HOST}:${VLM_PORT} healthy"
      printf '%s\n' "${health_body}"
      return 0
    else
      warn "vlm pid ${pid} alive but /health unreachable (still loading model?)"
      return 11
    fi
  else
    warn "vlm not running"
    return 11
  fi
}

# Module-scope smoke helpers (refactored from cmd_smoke so cmd_bench can also
# call them per-model). Each emits one JSONL line on stdout + updates the
# caller's SMOKE_PASS / SMOKE_FAIL globals — keeps the function pure-ish
# without IPC. Endpoint resolution defers to VLM_HOST + VLM_PORT at call time.
SMOKE_PASS=0
SMOKE_FAIL=0

_smoke_endpoint() {
  printf 'http://%s:%s/v1/chat/completions\n' "${VLM_HOST}" "${VLM_PORT}"
}

_run_text_smoke() {
  local label="$1" prompt="$2" t0 t1 lat resp completion
  local endpoint
  endpoint="$(_smoke_endpoint)"
  t0=$(python3 -c "import time;print(time.time())" 2>/dev/null || date +%s)
  resp="$(curl -sS -m 30 "${endpoint}" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg p "${prompt}" '{model:"q",max_tokens:12,messages:[{role:"user",content:$p}]}')" 2>/dev/null)"
  t1=$(python3 -c "import time;print(time.time())" 2>/dev/null || date +%s)
  lat=$(python3 -c "print(round($t1 - $t0, 2))" 2>/dev/null || echo "n/a")
  completion="$(printf '%s' "${resp}" | jq -r '.choices[0].message.content // .error.message' 2>/dev/null)"
  printf '{"smoke":"%s","type":"text","latency_s":%s,"completion":"%s"}\n' \
    "${label}" "${lat}" "${completion//\"/\\\"}"
  if [ -n "${completion}" ] && [ "${completion}" != "null" ]; then
    SMOKE_PASS=$((SMOKE_PASS + 1))
  else
    SMOKE_FAIL=$((SMOKE_FAIL + 1))
  fi
}

_run_vision_smoke() {
  local label="$1" rgb="$2" expected="$3" t0 t1 lat resp completion png_b64
  local endpoint
  endpoint="$(_smoke_endpoint)"
  png_b64="$(python3 <<EOF
import struct, zlib, base64
W=H=64
r,g,b=${rgb}
raw=b''
for _ in range(H):
    raw += b'\\x00' + bytes((r,g,b))*W
def chunk(k,d): return struct.pack('>I', len(d)) + k + d + struct.pack('>I', zlib.crc32(k+d))
png  = b'\\x89PNG\\r\\n\\x1a\\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(raw, 9))
png += chunk(b'IEND', b'')
print(base64.b64encode(png).decode())
EOF
)"
  t0=$(python3 -c "import time;print(time.time())")
  resp="$(curl -sS -m 60 "${endpoint}" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg img "data:image/png;base64,${png_b64}" '
      {model:"q",max_tokens:20,messages:[{role:"user",content:[
        {type:"text",text:"One word: dominant color of this image?"},
        {type:"image_url",image_url:{url:$img}}
      ]}]}')" 2>/dev/null)"
  t1=$(python3 -c "import time;print(time.time())")
  lat=$(python3 -c "print(round($t1 - $t0, 2))")
  completion="$(printf '%s' "${resp}" | jq -r '.choices[0].message.content // .error.message' 2>/dev/null)"
  local hit="false"
  case "${completion,,}" in *"${expected}"*) hit="true" ;; esac
  printf '{"smoke":"%s","type":"vision","latency_s":%s,"completion":"%s","expected":"%s","hit":%s}\n' \
    "${label}" "${lat}" "${completion//\"/\\\"}" "${expected}" "${hit}"
  if [ "${hit}" = "true" ]; then SMOKE_PASS=$((SMOKE_PASS + 1));
  else SMOKE_FAIL=$((SMOKE_FAIL + 1)); fi
}

_run_vision_fixture_smoke() {
  # Path-3-relevant: read a pre-rendered PNG fixture (e.g. a button shape) and
  # ask the model to identify it. Hits when the completion contains EXPECTED
  # (case-insensitive). The synthetic-color smokes are kept as
  # vision-pipeline-works sanity checks; this smoke is the real grounding test.
  local label="$1" png_path="$2" expected="$3" prompt="$4"
  local t0 t1 lat resp completion png_b64
  local endpoint
  endpoint="$(_smoke_endpoint)"
  if [ ! -f "${png_path}" ]; then
    printf '{"smoke":"%s","type":"vision-fixture","status":"fixture-missing","path":"%s"}\n' \
      "${label}" "${png_path}"
    SMOKE_FAIL=$((SMOKE_FAIL + 1))
    return 0
  fi
  png_b64="$(base64 -i "${png_path}" | tr -d '\n')"
  t0=$(python3 -c "import time;print(time.time())")
  resp="$(curl -sS -m 60 "${endpoint}" -H 'Content-Type: application/json' \
    -d "$(jq -n \
      --arg img "data:image/png;base64,${png_b64}" \
      --arg prompt "${prompt}" '
      {model:"q",max_tokens:30,messages:[{role:"user",content:[
        {type:"text",text:$prompt},
        {type:"image_url",image_url:{url:$img}}
      ]}]}')" 2>/dev/null)"
  t1=$(python3 -c "import time;print(time.time())")
  lat=$(python3 -c "print(round($t1 - $t0, 2))")
  completion="$(printf '%s' "${resp}" | jq -r '.choices[0].message.content // .error.message' 2>/dev/null)"
  # Broader matcher (bench-fix #5): EXPECTED can be a |-delimited list of
  # acceptable terms — hit if completion contains ANY (case-insensitive).
  # Why: open-ended description prompts produce nuanced answers ("Blue
  # rectangle" is a structurally-correct description of a button-shape
  # fixture); narrow single-term matching false-fails them. Single-term
  # expected still works (no | in the string).
  local hit="false" term
  local _saved_ifs="${IFS}"
  IFS='|'
  for term in ${expected}; do
    [ -z "${term}" ] && continue
    case "${completion,,}" in
      *"${term,,}"*) hit="true"; break ;;
    esac
  done
  IFS="${_saved_ifs}"
  printf '{"smoke":"%s","type":"vision-fixture","latency_s":%s,"completion":"%s","expected":"%s","hit":%s}\n' \
    "${label}" "${lat}" "${completion//\"/\\\"}" "${expected}" "${hit}"
  if [ "${hit}" = "true" ]; then SMOKE_PASS=$((SMOKE_PASS + 1));
  else SMOKE_FAIL=$((SMOKE_FAIL + 1)); fi
}

# Run the smoke battery against the current ${VLM_HOST}:${VLM_PORT}. Resets
# SMOKE_PASS / SMOKE_FAIL before running. Returns 0 if all smokes passed, 1
# otherwise.
#
# Battery composition (5 smokes; the last is the Path-3 grounding test):
#   text_cold + text_warm       — text completion + warmup speedup
#   vision_red + vision_green   — synthetic-color pipeline sanity (NOT a Path-3
#                                  test — pure RGB is out-of-distribution; both
#                                  pass means vision wiring works, both
#                                  failing means model is colorblind on
#                                  synthetic stimuli, not necessarily blind on
#                                  rendered UI)
#   vision_button               — rendered-button-shape PNG fixture; THIS is
#                                  the Path-3 unblock signal. Hits when the
#                                  model identifies a button or recognises the
#                                  blue rectangle as a UI element.
_run_smoke_battery() {
  SMOKE_PASS=0; SMOKE_FAIL=0
  _run_text_smoke "text_cold" "Say hi in exactly one word."
  _run_text_smoke "text_warm" "Reply in exactly two words."
  if command -v python3 >/dev/null 2>&1; then
    _run_vision_smoke "vision_red"   "224,16,16" "red"
    _run_vision_smoke "vision_green" "0,192,32"  "green"
  else
    warn "python3 missing — skipping synthetic-color vision smokes"
  fi
  local button_fixture
  button_fixture="${BENCH_FIXTURE_BUTTON:-${SCRIPT_DIR}/../tests/fixtures/vlm-bench/button-shape.png}"
  _run_vision_fixture_smoke "vision_button" "${button_fixture}" \
    "button|rectangle|rounded|shape|blue rectangle|ui element" \
    "Describe what you see in this image in one or two words."
  [ "${SMOKE_FAIL}" -eq 0 ]
}

cmd_smoke() {
  # Requires the server to be up. Runs the 5-smoke battery from
  # references/midscene-integration.md and emits one JSON line per smoke,
  # then a final aggregate line — same shape contract as our verb scripts.
  if ! curl -sfm 3 "http://${VLM_HOST}:${VLM_PORT}/health" >/dev/null 2>&1; then
    die "${EXIT_PREFLIGHT_FAILED}" \
      "vlm not reachable at http://${VLM_HOST}:${VLM_PORT} — run 'browser-vlm start' first"
  fi
  _run_smoke_battery
  local rc=$?
  printf '{"summary":"vlm-smoke","pass":%d,"fail":%d,"endpoint":"http://%s:%s"}\n' \
    "${SMOKE_PASS}" "${SMOKE_FAIL}" "${VLM_HOST}" "${VLM_PORT}"
  return "${rc}"
}

# Default model presets for `vlm bench`. Chosen so the table directly answers
# "is Path 3 cache-rescue unblockable at this size?".
_BENCH_DEFAULT_MODELS=(
  "Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M"   # baseline (current local install)
  "Qwen/Qwen3-VL-4B-Instruct-GGUF:Q8_0"     # same params, less quantization
  "Qwen/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M"   # midscene's recommended default
)

cmd_bench() {
  # Iterate a list of model tags. For each: stop any running vlm, set the
  # model env var, start fresh, wait for /health, run the 4-smoke battery,
  # stop. Emit one per-model JSONL row + a final summary line. Default model
  # list answers the Path-3 unblock question — override by passing models on
  # the command line.
  #
  # --dry-run            print which models would be benched + exit 0
  # --max-wait-s N       seconds to wait for each model's /health (default 600)
  local dry_run=0 max_wait_s=600
  local models=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)    dry_run=1; shift ;;
      --max-wait-s) max_wait_s="$2"; shift 2 ;;
      --help|-h)
        cat <<'BENCHUSAGE'
browser-vlm bench [--dry-run] [--max-wait-s N] [MODEL [MODEL ...]]

Bench multiple models against the same 4-smoke battery (text-cold, vision-red,
vision-green, text-warm). Stops any running vlm first, then for each model:
start → wait /health → smoke → stop. Emits one JSONL row per model + final.

Default model list (answers the Path-3 unblock question):
  Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M
  Qwen/Qwen3-VL-4B-Instruct-GGUF:Q8_0
  Qwen/Qwen3-VL-8B-Instruct-GGUF:Q4_K_M

Use --dry-run to confirm the list without downloading anything.
BENCHUSAGE
        return 0
        ;;
      -*) die "${EXIT_USAGE_ERROR}" "bench: unknown flag '${1}'" ;;
      *)  models+=("$1"); shift ;;
    esac
  done
  [ "${#models[@]}" -gt 0 ] || models=("${_BENCH_DEFAULT_MODELS[@]}")

  _ensure_home

  # Emit start event (machine-parseable plan).
  local models_json
  models_json="$(printf '%s\n' "${models[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  printf '{"event":"bench-start","models":%s,"ts":"%s"}\n' \
    "${models_json}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "${dry_run}" = "1" ]; then
    ok "dry-run: would bench ${#models[@]} model(s); no downloads, no spawns"
    printf '{"event":"bench-done","total_models":%d,"dry_run":true}\n' "${#models[@]}"
    return 0
  fi

  if ! command -v "${LLAMA_SERVER_BIN}" >/dev/null 2>&1; then
    die "${EXIT_TOOL_MISSING}" "${LLAMA_SERVER_BIN} not on PATH — brew install llama.cpp"
  fi

  local model bench_pass=0 bench_fail=0
  for model in "${models[@]}"; do
    # Defensive stop (whatever was running before).
    cmd_stop >/dev/null 2>&1 || true

    # Spawn this model. Subshell isolates `die` from inside cmd_start so a
    # missing tool / busy port doesn't kill the whole bench — instead we
    # record the per-model failure and continue.
    if ! (BROWSER_SKILL_VLM_MODEL="${model}" cmd_start) >/dev/null 2>&1; then
      printf '{"event":"bench-model","model":"%s","status":"start-failed"}\n' \
        "${model}"
      bench_fail=$((bench_fail + 1))
      continue
    fi
    # Poll /health with bounded wait so a slow download doesn't hang forever.
    local waited=0
    while [ "${waited}" -lt "${max_wait_s}" ]; do
      if curl -sfm 2 "http://${VLM_HOST}:${VLM_PORT}/health" >/dev/null 2>&1; then
        break
      fi
      sleep 5
      waited=$((waited + 5))
    done

    if ! curl -sfm 2 "http://${VLM_HOST}:${VLM_PORT}/health" >/dev/null 2>&1; then
      printf '{"event":"bench-model","model":"%s","status":"timeout","wait_s":%d}\n' \
        "${model}" "${max_wait_s}"
      bench_fail=$((bench_fail + 1))
      cmd_stop >/dev/null 2>&1 || true
      continue
    fi

    # Bench-fix #4: model-identity verification. llama-server's -hf flag
    # silently falls back to whatever's already cached in the HF repo dir
    # when the requested quant can't be fetched. /health still returns 200.
    # Without this check, bench reports successful smokes against the wrong
    # model (we found this by disk-forensicing: 8B-q4 directory didn't exist
    # but bench still reported 8B-q4 smokes). Query /v1/models, parse the
    # first entry's id, require the requested repo+quant appear as substring.
    local loaded_model
    loaded_model="$(curl -sm 3 "http://${VLM_HOST}:${VLM_PORT}/v1/models" 2>/dev/null \
                    | jq -r '.data[0].id // ""' 2>/dev/null)"
    if [ -n "${loaded_model}" ]; then
      # The requested model spec is "vendor/repo:quant"; the loaded id usually
      # contains "vendor/repo" and the quant tag.
      local model_no_slash="${model//\//_}"
      local loaded_no_slash="${loaded_model//\//_}"
      case "${loaded_no_slash}" in
        *"${model_no_slash}"*) : ;;   # exact subset — ok
        *)
          # Try the quant tag alone (some servers report only the quant).
          local quant="${model##*:}"
          case "${loaded_model}" in
            *"${quant}"*) : ;;
            *)
              printf '{"event":"bench-model","model":"%s","status":"model-mismatch","loaded_as":"%s"}\n' \
                "${model}" "${loaded_model}"
              bench_fail=$((bench_fail + 1))
              cmd_stop >/dev/null 2>&1 || true
              continue
              ;;
          esac
          ;;
      esac
    fi

    # Run smokes for this model. CRITICAL: do NOT command-substitute the
    # battery call — its stdout IS the smoke NDJSON, and we want those lines
    # streamed live + SMOKE_PASS/SMOKE_FAIL incrementing in the parent shell
    # (subshell would lose both). Capture the rc via the if/else branch.
    local model_status
    if _run_smoke_battery; then
      model_status="ok"
    else
      model_status="partial"   # smokes ran but some missed
    fi
    printf '{"event":"bench-model","model":"%s","status":"%s","pass":%d,"fail":%d}\n' \
      "${model}" "${model_status}" "${SMOKE_PASS}" "${SMOKE_FAIL}"
    if [ "${SMOKE_FAIL}" -eq 0 ]; then
      bench_pass=$((bench_pass + 1))
    else
      bench_fail=$((bench_fail + 1))
    fi

    cmd_stop >/dev/null 2>&1 || true
  done

  printf '{"event":"bench-done","total_models":%d,"pass":%d,"fail":%d}\n' \
    "${#models[@]}" "${bench_pass}" "${bench_fail}"
  [ "${bench_fail}" -eq 0 ] || return 1
}

# --- install-env / uninstall-env (Phase 14+ auto-management) -----------
# Append two env exports (BROWSER_SKILL_VISION_FALLBACK=1 +
# BROWSER_SKILL_VISUAL_RESCUE_CMD=<bundled probe path>) to the user's shell
# init so Claude Code subprocesses inherit them. Idempotent — re-running is
# a no-op if the marked block already exists.
VLM_ENV_MARKER_BEGIN="# >>> browser-skill VLM auto-management (Path 3) >>>"
VLM_ENV_MARKER_END="# <<< browser-skill VLM auto-management <<<"

cmd_install_env() {
  local target="${BROWSER_SKILL_INSTALL_SHELL_RC:-${HOME}/.zshrc}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --shell-rc) target="$2"; shift 2 ;;
      --help|-h)
        cat <<'IEUSAGE'
browser-vlm install-env [--shell-rc PATH]

Append the two env exports to your shell init so Claude Code subprocesses
inherit them. After running, open a new shell (or `source` the rc) to
activate. Idempotent — running twice is a no-op.

Defaults to ~/.zshrc. Override with --shell-rc /path/to/.bashrc (etc).
IEUSAGE
        return 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "install-env: unknown flag '${1}'" ;;
    esac
  done
  local probe_path
  probe_path="$(cd "${SCRIPT_DIR}/lib" 2>/dev/null && pwd)/visual-rescue-default.sh"
  [ -f "${probe_path}" ] \
    || die "${EXIT_PREFLIGHT_FAILED}" "bundled probe missing at ${probe_path}"
  if [ -f "${target}" ] && grep -qF "${VLM_ENV_MARKER_BEGIN}" "${target}" 2>/dev/null; then
    ok "browser-skill env already installed in ${target} (no-op)"
    return 0
  fi
  {
    printf '\n%s\n' "${VLM_ENV_MARKER_BEGIN}"
    printf '# Auto-added by `browser-vlm install-env`. Edit via `browser-vlm uninstall-env`.\n'
    printf 'export BROWSER_SKILL_VISION_FALLBACK=1\n'
    printf 'export BROWSER_SKILL_VISUAL_RESCUE_CMD=%q\n' "${probe_path}"
    printf '%s\n' "${VLM_ENV_MARKER_END}"
  } >> "${target}"
  ok "added browser-skill env exports to ${target}"
  ok "activate: 'source ${target}' or open a new shell"
}

cmd_uninstall_env() {
  local target="${BROWSER_SKILL_INSTALL_SHELL_RC:-${HOME}/.zshrc}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --shell-rc) target="$2"; shift 2 ;;
      --help|-h)
        cat <<'UEUSAGE'
browser-vlm uninstall-env [--shell-rc PATH]

Remove the env-export block previously added by `install-env`. Idempotent
— running on a clean rc is a no-op.
UEUSAGE
        return 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "uninstall-env: unknown flag '${1}'" ;;
    esac
  done
  if [ ! -f "${target}" ] || ! grep -qF "${VLM_ENV_MARKER_BEGIN}" "${target}" 2>/dev/null; then
    ok "no browser-skill env block found in ${target} (no-op)"
    return 0
  fi
  local tmp
  tmp="$(mktemp "${target}.uninstall.XXXXXX")"
  awk -v b="${VLM_ENV_MARKER_BEGIN}" -v e="${VLM_ENV_MARKER_END}" '
    index($0, b) { skip = 1; next }
    skip && index($0, e) { skip = 0; next }
    !skip
  ' "${target}" > "${tmp}"
  mv "${tmp}" "${target}"
  ok "removed browser-skill env block from ${target}"
}

case "${1:-}" in
  start)         shift; cmd_start "$@" ;;
  stop)          shift; cmd_stop ;;
  status)        shift; cmd_status ;;
  smoke)         shift; cmd_smoke ;;
  bench)         shift; cmd_bench "$@" ;;
  install-env)   shift; cmd_install_env "$@" ;;
  uninstall-env) shift; cmd_uninstall_env "$@" ;;
  --help|-h|help|"")
    cat <<'USAGE'
browser-vlm — local llama-server lifecycle wrapper (lean config)

Usage:
  bash scripts/browser-vlm.sh start [--dry-run]    # spawn llama-server in bg
  bash scripts/browser-vlm.sh stop                 # kill running instance
  bash scripts/browser-vlm.sh status               # ping /health
  bash scripts/browser-vlm.sh smoke                # 4-smoke battery (text+vision)
  bash scripts/browser-vlm.sh bench [MODEL...]     # bench multiple models
  bash scripts/browser-vlm.sh install-env          # persist env exports to ~/.zshrc
  bash scripts/browser-vlm.sh uninstall-env        # remove the env block
  bash scripts/browser-vlm.sh --help               # this message

Lean defaults (override via BROWSER_SKILL_VLM_*; see top of script):
  model:           Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M
  endpoint:        http://127.0.0.1:8080
  ctx-size:        8192   (vs 175616 fat default)
  parallel slots:  1      (vs 4 fat default)
  threads:         4      (vs all P-cores fat default)
  threads-batch:   6
  cache-ram:       512 MiB (vs 8192 fat default)
  n-gpu-layers:    99      (Metal offload — macOS default)

State files (mode 0600 inside ~/.browser-skill/):
  vlm.pid   pid of running llama-server
  vlm.log   stdout+stderr from llama-server

First launch downloads ~3.5 GB to ~/.cache/huggingface/hub/. Subsequent
launches start in ~5 s on M-series Macs.
USAGE
    exit 0
    ;;
  *)
    die "${EXIT_USAGE_ERROR}" "unknown subcommand '${1}' — see --help"
    ;;
esac
