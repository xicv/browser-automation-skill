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
}

cmd_stop() {
  if existing="$(_read_pid)" && _pid_alive "${existing}"; then
    kill "${existing}" 2>/dev/null || true
    # Give it 2s to exit cleanly; SIGKILL if still alive.
    local i
    for i in 1 2 3 4; do
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
  rm -f "${VLM_PID_FILE}" 2>/dev/null || true
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

cmd_smoke() {
  # Requires the server to be up. Runs the 4 smokes from
  # references/midscene-integration.md and emits one JSON summary per smoke,
  # then a final aggregate line — same shape contract as our verb scripts.
  if ! curl -sfm 3 "http://${VLM_HOST}:${VLM_PORT}/health" >/dev/null 2>&1; then
    die "${EXIT_PREFLIGHT_FAILED}" \
      "vlm not reachable at http://${VLM_HOST}:${VLM_PORT} — run 'browser-vlm start' first"
  fi

  local endpoint="http://${VLM_HOST}:${VLM_PORT}/v1/chat/completions"
  local total_pass=0 total_fail=0

  _run_text_smoke() {
    local label="$1" prompt="$2" t0 t1 lat resp completion
    t0=$(python3 -c "import time;print(time.time())" 2>/dev/null || date +%s)
    resp="$(curl -sS -m 30 "${endpoint}" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg p "${prompt}" '{model:"q",max_tokens:12,messages:[{role:"user",content:$p}]}')" 2>/dev/null)"
    t1=$(python3 -c "import time;print(time.time())" 2>/dev/null || date +%s)
    lat=$(python3 -c "print(round($t1 - $t0, 2))" 2>/dev/null || echo "n/a")
    completion="$(printf '%s' "${resp}" | jq -r '.choices[0].message.content // .error.message' 2>/dev/null)"
    printf '{"smoke":"%s","type":"text","latency_s":%s,"completion":"%s"}\n' \
      "${label}" "${lat}" "${completion//\"/\\\"}"
    if [ -n "${completion}" ] && [ "${completion}" != "null" ]; then
      total_pass=$((total_pass + 1))
    else
      total_fail=$((total_fail + 1))
    fi
  }

  _run_text_smoke "text_cold" "Say hi in exactly one word."
  _run_text_smoke "text_warm" "Reply in exactly two words."

  # Vision smokes only if Python available for image synth (stdlib only).
  if command -v python3 >/dev/null 2>&1; then
    _run_vision_smoke() {
      local label="$1" rgb="$2" expected="$3" t0 t1 lat resp completion png_b64
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
      if [ "${hit}" = "true" ]; then total_pass=$((total_pass + 1));
      else total_fail=$((total_fail + 1)); fi
    }
    _run_vision_smoke "vision_red"   "224,16,16"   "red"
    _run_vision_smoke "vision_green" "0,192,32"    "green"
  else
    warn "python3 missing — skipping vision smokes"
  fi

  printf '{"summary":"vlm-smoke","pass":%d,"fail":%d,"endpoint":"%s"}\n' \
    "${total_pass}" "${total_fail}" "${endpoint}"
  [ "${total_fail}" -eq 0 ] || return 1
}

case "${1:-}" in
  start)   shift; cmd_start "$@" ;;
  stop)    shift; cmd_stop ;;
  status)  shift; cmd_status ;;
  smoke)   shift; cmd_smoke ;;
  --help|-h|help|"")
    cat <<'USAGE'
browser-vlm — local llama-server lifecycle wrapper (lean config)

Usage:
  bash scripts/browser-vlm.sh start [--dry-run]    # spawn llama-server in bg
  bash scripts/browser-vlm.sh stop                 # kill running instance
  bash scripts/browser-vlm.sh status               # ping /health
  bash scripts/browser-vlm.sh smoke                # 4-smoke battery (text+vision)
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
