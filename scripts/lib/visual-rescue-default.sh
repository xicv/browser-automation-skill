#!/usr/bin/env bash
# scripts/lib/visual-rescue-default.sh — canonical Path 3 probe (text-mode).
#
# Implements the BROWSER_SKILL_VISUAL_RESCUE_CMD hook contract from
# scripts/browser-do.sh (Phase 14 Path 3). Decides whether a cached selector
# is still semantically present on the page by sending the CURRENT
# accessibility snapshot + the original intent to a local OpenAI-compatible
# VLM endpoint (default: http://127.0.0.1:8080 — same as scripts/browser-vlm.sh).
#
# Mode: text-based (v1). Reads the accessibility-tree YAML snapshot (cheap,
# ~2KB) and asks the VLM yes/no. NO screenshot is sent — a true vision-mode
# default ships in a future commit once the screenshot-from-live-session
# infrastructure lands.
#
# Why this is the right v1 default:
#   - llama-server's text completion is much faster than vision (~200ms vs ~1500ms)
#   - works against ANY OpenAI-compatible LLM, not just VLMs
#   - accessibility snapshots already encode what UI is visible
#   - no new infrastructure needed (browser-snapshot.sh is shipped)
#
# Hook contract (per browser-do.sh):
#   $1 SITE   $2 INTENT   $3 CACHED_SELECTOR
#   exit 0 + stdout "yes" → cache rescued
#   exit 0 + stdout "no"  → fall through to cloud LLM
#   non-zero exit         → fall through (treated as "unreachable")
#
# Env overrides:
#   BROWSER_SKILL_VLM_HOST            127.0.0.1
#   BROWSER_SKILL_VLM_PORT            8080
#   BROWSER_SKILL_VLM_RESCUE_MODEL    "q"  (arbitrary tag; llama-server ignores)
#   BROWSER_SKILL_VLM_RESCUE_TIMEOUT  30   (seconds, end-to-end)
#   BROWSER_SKILL_SCRIPTS_DIR         derived from BASH_SOURCE if unset
#   BROWSER_SKILL_RESCUE_SNAPSHOT_BYTES  2048 (truncation cap for snapshot text)

set -euo pipefail
IFS=$'\n\t'

site="${1:-}"
intent="${2:-}"
selector="${3:-}"

if [ -z "${site}" ] || [ -z "${intent}" ] || [ -z "${selector}" ]; then
  echo "no"
  exit 2
fi

vlm_host="${BROWSER_SKILL_VLM_HOST:-127.0.0.1}"
vlm_port="${BROWSER_SKILL_VLM_PORT:-8080}"
vlm_model="${BROWSER_SKILL_VLM_RESCUE_MODEL:-q}"
vlm_timeout="${BROWSER_SKILL_VLM_RESCUE_TIMEOUT:-30}"
snap_cap="${BROWSER_SKILL_RESCUE_SNAPSHOT_BYTES:-2048}"
endpoint="http://${vlm_host}:${vlm_port}/v1/chat/completions"

# Gate 1: reachability. With lazy auto-start (default ON), the probe will
# try to spawn llama-server via browser-vlm.sh if it's down, and poll
# /health up to BROWSER_SKILL_LAZY_START_TIMEOUT seconds (default 60).
# Disable lazy-start by setting BROWSER_SKILL_LAZY_START=0 (the probe then
# fails fast like v1).
if ! curl -sfm 2 "http://${vlm_host}:${vlm_port}/health" >/dev/null 2>&1; then
  if [ "${BROWSER_SKILL_LAZY_START:-1}" = "1" ]; then
    SCRIPTS_DIR_FOR_VLM="${BROWSER_SKILL_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    vlm_script="${SCRIPTS_DIR_FOR_VLM}/browser-vlm.sh"
    if [ -f "${vlm_script}" ]; then
      # Start in background — browser-vlm.sh handles nohup + pidfile.
      bash "${vlm_script}" start >/dev/null 2>&1 || true
      # Poll until /health responds OR timeout.
      timeout_s="${BROWSER_SKILL_LAZY_START_TIMEOUT:-60}"
      waited=0
      while [ "${waited}" -lt "${timeout_s}" ]; do
        if curl -sfm 2 "http://${vlm_host}:${vlm_port}/health" >/dev/null 2>&1; then
          break
        fi
        sleep 2
        waited=$((waited + 2))
      done
    fi
  fi
  # Final reachability check — if still down, give up gracefully.
  if ! curl -sfm 2 "http://${vlm_host}:${vlm_port}/health" >/dev/null 2>&1; then
    echo "no"
    exit 1
  fi
fi

# Gate 2: locate browser-snapshot.sh. Default to the skill's own scripts dir
# resolved from this file's location.
SCRIPTS_DIR="${BROWSER_SKILL_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
snap_script="${SCRIPTS_DIR}/browser-snapshot.sh"
if [ ! -x "${snap_script}" ] && [ ! -f "${snap_script}" ]; then
  echo "no"
  exit 1
fi

# Gate 3: snapshot. browser-snapshot.sh emits NDJSON with summary as final
# line; large snapshots get a snapshot_path reference (Phase 14 #1).
snap_out="$(bash "${snap_script}" --site "${site}" 2>/dev/null | tail -1)"
[ -n "${snap_out}" ] || { echo "no"; exit 1; }

snap_text=""
snap_path="$(printf '%s' "${snap_out}" | jq -r '.snapshot_path // ""' 2>/dev/null)"
if [ -n "${snap_path}" ] && [ -f "${snap_path}" ]; then
  snap_text="$(head -c "${snap_cap}" "${snap_path}")"
fi

# Fallback: no snapshot_path means inline (small page); just use whatever
# the summary itself carried as observed text. If neither path nor inline
# data lands, treat as unreachable.
if [ -z "${snap_text}" ]; then
  snap_text="$(printf '%s' "${snap_out}" \
    | jq -r '.url // "", .title // ""' 2>/dev/null \
    | tr '\n' ' ' \
    | head -c "${snap_cap}")"
fi

[ -n "${snap_text}" ] || { echo "no"; exit 1; }

# Gate 4: VLM probe. Yes/no prompt.
prompt="A user wants to: '${intent}'. The cached element selector was '${selector}'. Here is the current page's accessibility snapshot (first ${snap_cap} bytes):

${snap_text}

Based ONLY on the snapshot, is there still an element on the page that matches the user's intent? Reply with ONLY one word: 'yes' or 'no'."

resp="$(curl -sS -m "${vlm_timeout}" "${endpoint}" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg p "${prompt}" --arg m "${vlm_model}" '
    {model:$m, max_tokens:5,
     messages:[{role:"user",content:$p}]}')" 2>/dev/null)" \
  || { echo "no"; exit 1; }

completion="$(printf '%s' "${resp}" | jq -r '.choices[0].message.content // ""' 2>/dev/null)"

case "${completion,,}" in
  *yes*) echo "yes"; ;;
  *)     echo "no"; ;;
esac

# Phase 14+: touch a tracker file so the idle-stop watchdog (browser-vlm.sh
# start spawns one) can tell when the VLM was last actually used. Without
# this, /health pings from doctor + manual status checks would keep the
# server alive forever.
BROWSER_SKILL_HOME="${BROWSER_SKILL_HOME:-${HOME}/.browser-skill}"
mkdir -p "${BROWSER_SKILL_HOME}" 2>/dev/null || true
: > "${BROWSER_SKILL_HOME}/vlm.last-used" 2>/dev/null || true
exit 0
