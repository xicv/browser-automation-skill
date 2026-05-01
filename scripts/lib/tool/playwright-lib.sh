# scripts/lib/tool/playwright-lib.sh — Playwright (node-bridge) tool adapter.
#
# Implements the Tool Adapter Extension Model contract from
# docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md §2.
#
# Routes verb dispatch to scripts/lib/node/playwright-driver.mjs which speaks
# the real Playwright API. Stub mode (BROWSER_SKILL_LIB_STUB=1) is used by
# tests + CI; real mode lands when the driver's real branch ships.
#
# Distinction from playwright-cli adapter:
# - playwright-cli shells to a binary that takes positional args (translation
#   needed at adapter boundary).
# - playwright-lib shells to a node script that speaks skill-flag surface
#   directly (driver constructs Playwright API calls), so no translation here.
# - playwright-lib supports --secret-stdin natively (driver reads stdin in node).
# - playwright-lib supports session loading via BROWSER_SKILL_STORAGE_STATE env.

[ -n "${_BROWSER_TOOL_PLAYWRIGHT_LIB_LOADED:-}" ] && return 0
readonly _BROWSER_TOOL_PLAYWRIGHT_LIB_LOADED=1

# Required by spec 2026-05-01-token-efficient-adapter-output-design §8.
# shellcheck source=../output.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../output.sh"

readonly _BROWSER_TOOL_PLAYWRIGHT_LIB_NODE_BIN="${BROWSER_SKILL_NODE_BIN:-node}"
readonly _BROWSER_TOOL_PLAYWRIGHT_LIB_DRIVER="$(dirname "${BASH_SOURCE[0]}")/../node/playwright-driver.mjs"

# --- Identity functions ---

tool_metadata() {
  cat <<'EOF'
{
  "name": "playwright-lib",
  "abi_version": 1,
  "version_pin": "1.59.x",
  "cheatsheet_path": "references/playwright-lib-cheatsheet.md",
  "install_hint": "npm i -g playwright @playwright/test && playwright install chromium"
}
EOF
}

tool_capabilities() {
  cat <<'EOF'
{
  "verbs": {
    "open":     { "flags": ["--headed", "--viewport", "--user-agent", "--storage-state"] },
    "click":    { "flags": ["--ref", "--selector"] },
    "fill":     { "flags": ["--ref", "--text", "--secret-stdin"] },
    "snapshot": { "flags": ["--depth"] },
    "login":    { "flags": ["--storage-state"] }
  },
  "session_load": true
}
EOF
}

tool_doctor_check() {
  if ! command -v "${_BROWSER_TOOL_PLAYWRIGHT_LIB_NODE_BIN}" >/dev/null 2>&1; then
    cat <<EOF
{ "ok": false, "binary": "${_BROWSER_TOOL_PLAYWRIGHT_LIB_NODE_BIN}", "error": "node not on PATH",
  "install_hint": "brew install node (>=20)" }
EOF
    return 0
  fi
  if [ ! -f "${_BROWSER_TOOL_PLAYWRIGHT_LIB_DRIVER}" ]; then
    printf '{"ok":false,"binary":"%s","error":"driver missing","driver_path":"%s"}\n' \
      "${_BROWSER_TOOL_PLAYWRIGHT_LIB_NODE_BIN}" "${_BROWSER_TOOL_PLAYWRIGHT_LIB_DRIVER}"
    return 0
  fi
  local node_version
  node_version="$("${_BROWSER_TOOL_PLAYWRIGHT_LIB_NODE_BIN}" --version 2>/dev/null || printf 'unknown')"
  printf '{"ok":true,"binary":"%s","node_version":"%s"}\n' \
    "${_BROWSER_TOOL_PLAYWRIGHT_LIB_NODE_BIN}" "${node_version}"
}

# --- Verb-dispatch functions ---
# Driver receives skill-flag argv directly; no translation needed.
# BROWSER_SKILL_STORAGE_STATE (set by verb script when --site/--as resolved)
# is forwarded as --storage-state PATH to the driver when present.

_drive() {
  local verb="$1"
  shift
  local extra=()
  if [ -n "${BROWSER_SKILL_STORAGE_STATE:-}" ]; then
    extra+=(--storage-state "${BROWSER_SKILL_STORAGE_STATE}")
  fi
  "${_BROWSER_TOOL_PLAYWRIGHT_LIB_NODE_BIN}" "${_BROWSER_TOOL_PLAYWRIGHT_LIB_DRIVER}" \
    "${verb}" "${extra[@]}" "$@"
}

tool_open()     { _drive open     "$@"; }
tool_click()    { _drive click    "$@"; }
tool_fill()     { _drive fill     "$@"; }
tool_snapshot() { _drive snapshot "$@"; }
tool_inspect()  { return 41; }   # Phase 5 chrome-devtools-mcp territory.
tool_audit()    { return 41; }
tool_extract()  { return 41; }
tool_eval()     { _drive eval     "$@"; }

# Phase-2 carry-forward: login was emitted with tool=playwright-lib-stub before
# this adapter existed. Now login routes here; verb script's tool field becomes
# tool=playwright-lib. The driver's stub mode currently echoes a canned login
# fixture; real mode launches a headed browser for storageState capture.
tool_login() { _drive login "$@"; }
