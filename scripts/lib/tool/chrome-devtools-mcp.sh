# scripts/lib/tool/chrome-devtools-mcp.sh — Chrome DevTools MCP tool adapter.
#
# Implements the Tool Adapter Extension Model contract from
# docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md §2.
#
# Identity: tool_metadata, tool_capabilities, tool_doctor_check
# Verb dispatch: tool_open, tool_click, tool_fill, tool_snapshot,
#                tool_inspect, tool_audit, tool_extract, tool_eval
#
# Path A introduction: this adapter is reachable only via
# `--tool=chrome-devtools-mcp`. Router promotion (Path B) for verbs like
# `inspect`, `audit`, and capture-flag variants of primitives (per parent spec
# Appendix B) is deferred to phase-05 part 1d.
#
# Architecture (phase-05 parts 1b / 1c / 1c-ii):
# Verb-dispatch shells to a node ESM bridge at
# scripts/lib/node/chrome-devtools-bridge.mjs which mirrors playwright-lib's
# playwright-driver.mjs:
# - Stub mode (BROWSER_SKILL_LIB_STUB=1): bridge looks up sha256(argv) in
#   tests/fixtures/chrome-devtools-mcp/<sha>.json and echoes the contents.
# - Real mode (one-shot): bridge spawns ${CHROME_DEVTOOLS_MCP_BIN} per call,
#   does the MCP initialize handshake, dispatches one tools/call, exits.
#   Used for stateless verbs (open / snapshot / eval / audit) when no daemon.
# - Real mode (daemon, part 1c-ii): bridge daemon-start spawns a long-lived
#   MCP child, holds the eN↔uid ref map, exposes verb dispatch over TCP
#   loopback IPC. Stateful verbs (click / fill) require a running daemon and
#   route through it. State at ${BROWSER_SKILL_HOME}/cdt-mcp-daemon.json.
#
# CHROME_DEVTOOLS_MCP_BIN env var semantics: in part 1 this was "the binary
# the adapter shells to (real or stub)"; in part 1b it shifts to "the upstream
# MCP server binary the bridge spawns in real mode". In stub mode it is
# unused. The shift is documented in CHANGELOG and the cheatsheet.
#
# Adapters are LEAVES — never source another adapter (AP-2). Shared logic
# factors into scripts/lib/<concern>.sh (sibling to lib/tool/).

[ -n "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_LOADED:-}" ] && return 0
readonly _BROWSER_TOOL_CHROME_DEVTOOLS_MCP_LOADED=1

# Required by spec 2026-05-01-token-efficient-adapter-output-design §8: every
# adapter sources output.sh so verb-dispatch emits JSON via emit_summary /
# emit_event rather than hand-rolled printf. Lint tier 3 enforces this.
# shellcheck source=../output.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../output.sh"

readonly _BROWSER_TOOL_CHROME_DEVTOOLS_MCP_NODE_BIN="${BROWSER_SKILL_NODE_BIN:-node}"
readonly _BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BRIDGE="$(dirname "${BASH_SOURCE[0]}")/../node/chrome-devtools-bridge.mjs"
readonly _BROWSER_TOOL_CHROME_DEVTOOLS_MCP_MCP_SERVER_BIN="${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}"

# --- Identity functions ---

tool_metadata() {
  cat <<'EOF'
{
  "name": "chrome-devtools-mcp",
  "abi_version": 1,
  "version_pin": "0.x",
  "cheatsheet_path": "references/chrome-devtools-mcp-cheatsheet.md",
  "install_hint": "npm i -g chrome-devtools-mcp (or run via 'npx chrome-devtools-mcp@latest' over stdio MCP)"
}
EOF
}

tool_capabilities() {
  cat <<'EOF'
{
  "verbs": {
    "open":     { "flags": ["--headed", "--url"] },
    "click":    { "flags": ["--ref"] },
    "fill":     { "flags": ["--ref", "--text", "--secret-stdin"] },
    "snapshot": { "flags": ["--depth"] },
    "inspect":  { "flags": ["--capture-console", "--capture-network", "--screenshot"] },
    "audit":    { "flags": ["--lighthouse", "--perf-trace"] },
    "extract":  { "flags": ["--selector", "--eval"] },
    "eval":     { "flags": ["--expression"] }
  }
}
EOF
}

tool_doctor_check() {
  if ! command -v "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_NODE_BIN}" >/dev/null 2>&1; then
    cat <<EOF
{ "ok": false, "binary": "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_NODE_BIN}", "error": "node not on PATH",
  "install_hint": "brew install node (>=20)" }
EOF
    return 0
  fi
  if [ ! -f "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BRIDGE}" ]; then
    printf '{"ok":false,"binary":"%s","error":"bridge missing","bridge_path":"%s"}\n' \
      "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_NODE_BIN}" "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BRIDGE}"
    return 0
  fi
  local node_version
  node_version="$("${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_NODE_BIN}" --version 2>/dev/null || printf 'unknown')"
  printf '{"ok":true,"binary":"%s","node_version":"%s","mcp_server_bin":"%s","note":"real-mode MCP transport: 8/8 verbs (open/snapshot/eval/audit/inspect/extract one-shot or daemon; click/fill require daemon)"}\n' \
    "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_NODE_BIN}" "${node_version}" "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_MCP_SERVER_BIN}"
}

# --- Verb-dispatch functions ---
# Argv translation: skill flags → bridge's `<verb> [args...]` surface. Bridge
# in stub mode hashes that surface (sha256 of args joined+terminated by NUL)
# and looks up the fixture. Bridge in real mode (part 1c) translates to
# MCP `tools/call` requests against the upstream chrome-devtools-mcp server.

_drive() {
  "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_NODE_BIN}" "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BRIDGE}" "$@"
}

tool_open() {
  local url=""
  local rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url) url="$2"; shift 2 ;;
      *)     rest+=("$1"); shift ;;
    esac
  done
  if [ -n "${url}" ]; then
    _drive open "${url}" "${rest[@]}"
  else
    _drive open "${rest[@]}"
  fi
}

tool_click() {
  local target=""
  local rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ref|--selector) target="$2"; shift 2 ;;
      *)                rest+=("$1"); shift ;;
    esac
  done
  [ -n "${target}" ] || return 41
  _drive click "${target}" "${rest[@]}"
}

tool_fill() {
  local target="" text="" use_stdin=0
  local rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ref)           target="$2"; shift 2 ;;
      --text)          text="$2";   shift 2 ;;
      --secret-stdin)  use_stdin=1; shift ;;
      *)               rest+=("$1"); shift ;;
    esac
  done
  [ -n "${target}" ] || return 41
  if [ "${use_stdin}" = "1" ]; then
    _drive fill "${target}" --secret-stdin "${rest[@]}"
    return $?
  fi
  [ -n "${text}" ] || return 41
  _drive fill "${target}" "${text}" "${rest[@]}"
}

tool_snapshot() {
  _drive snapshot "$@"
}

tool_inspect() {
  _drive inspect "$@"
}

tool_audit() {
  _drive audit "$@"
}

tool_extract() {
  _drive extract "$@"
}

tool_eval() {
  local expression=""
  local rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expression) expression="$2"; shift 2 ;;
      *)            rest+=("$1"); shift ;;
    esac
  done
  if [ -n "${expression}" ]; then
    _drive eval "${expression}" "${rest[@]}"
  else
    _drive eval "${rest[@]}"
  fi
}
