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
# Appendix B) is deferred to phase-05 part 1c.
#
# Real-mode bridge: the upstream `chrome-devtools-mcp` is an MCP server (npx
# stdio JSON-RPC), not a CLI. The bridge that speaks MCP to it is deferred to
# phase-05 part 1b. Today, this adapter shells to ${CHROME_DEVTOOLS_MCP_BIN}
# (default: chrome-devtools-mcp). On test boxes the bin is overridden to the
# stub at tests/stubs/chrome-devtools-mcp; on production boxes without the bin
# on PATH, verb-dispatch fails with the bin-not-found error and tool_doctor
# surfaces the missing-binary state explicitly.
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

readonly _BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN="${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}"

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
  if ! command -v "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" >/dev/null 2>&1; then
    cat <<EOF
{ "ok": false, "binary": "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}", "error": "not on PATH",
  "install_hint": "npm i -g chrome-devtools-mcp (or run via 'npx chrome-devtools-mcp@latest' over stdio MCP)",
  "note": "real-mode MCP stdio bridge deferred to phase-05 part 1b" }
EOF
    return 0
  fi
  local version
  version="$("${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" --version 2>/dev/null || printf 'unknown')"
  printf '{"ok":true,"binary":"%s","version":"%s"}\n' \
    "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" "${version}"
}

# --- Verb-dispatch functions ---
# Argv translation: skill flags → bin's positional + canonical flags. The bin
# (real or stub) sees a stable surface: `<verb> [args...]`. The stub fixtures
# are keyed by sha256 of that surface, so any translation change here requires
# regenerating fixture filenames.

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
    "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" open "${url}" "${rest[@]}"
  else
    "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" open "${rest[@]}"
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
  "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" click "${target}" "${rest[@]}"
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
    # chrome-devtools-mcp's fill_form MCP tool can stage values from a stdin
    # JSON envelope. We pass --secret-stdin through; the bin reads stdin.
    "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" fill "${target}" --secret-stdin "${rest[@]}"
    return $?
  fi
  [ -n "${text}" ] || return 41
  "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" fill "${target}" "${text}" "${rest[@]}"
}

tool_snapshot() {
  "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" snapshot "$@"
}

tool_inspect() {
  "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" inspect "$@"
}

tool_audit() {
  "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" audit "$@"
}

tool_extract() {
  "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" extract "$@"
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
    "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" eval "${expression}" "${rest[@]}"
  else
    "${_BROWSER_TOOL_CHROME_DEVTOOLS_MCP_BIN}" eval "${rest[@]}"
  fi
}
