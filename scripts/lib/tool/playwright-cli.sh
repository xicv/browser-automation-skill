# scripts/lib/tool/playwright-cli.sh — Playwright CLI tool adapter.
#
# Implements the Tool Adapter Extension Model contract from
# docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md §2.
#
# Identity: tool_metadata, tool_capabilities, tool_doctor_check
# Verb dispatch: tool_open, tool_click, tool_fill, tool_snapshot, tool_inspect,
#                tool_audit, tool_extract, tool_eval
# All verb-dispatch functions in this file currently shell to the playwright
# binary (real path) OR to ${PLAYWRIGHT_CLI_BIN:-playwright} (overridable for
# tests, which set it to tests/stubs/playwright-cli).
#
# Adapters are LEAVES — never source another adapter. Shared logic factors into
# scripts/lib/<concern>.sh (sibling to lib/tool/).

[ -n "${_BROWSER_TOOL_PLAYWRIGHT_CLI_LOADED:-}" ] && return 0
readonly _BROWSER_TOOL_PLAYWRIGHT_CLI_LOADED=1

# Required by spec 2026-05-01-token-efficient-adapter-output-design §8: every
# adapter sources output.sh so verb-dispatch emits JSON via emit_summary /
# emit_event rather than hand-rolled printf. Lint tier 3 enforces this.
# shellcheck source=../output.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../output.sh"

readonly _BROWSER_TOOL_PLAYWRIGHT_CLI_BIN="${PLAYWRIGHT_CLI_BIN:-playwright}"
readonly _BROWSER_TOOL_PLAYWRIGHT_CLI_DEFAULT_VIEWPORT="1280x800"

# --- Identity functions (called by framework once or for queries) ---

tool_metadata() {
  cat <<'EOF'
{
  "name": "playwright-cli",
  "abi_version": 1,
  "version_pin": "1.49.x",
  "cheatsheet_path": "references/playwright-cli-cheatsheet.md"
}
EOF
}

tool_capabilities() {
  cat <<'EOF'
{
  "verbs": {
    "open":     { "flags": ["--headed", "--viewport", "--user-agent"] },
    "click":    { "flags": ["--ref", "--selector"] },
    "fill":     { "flags": ["--ref", "--text", "--secret-stdin"] },
    "snapshot": { "flags": [] },
    "inspect":  { "flags": ["--selector"] }
  }
}
EOF
}

tool_doctor_check() {
  if ! command -v "${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}" >/dev/null 2>&1; then
    cat <<EOF
{ "ok": false, "binary": "${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}", "error": "not on PATH",
  "install_hint": "npm i -g playwright @playwright/test && playwright install chromium" }
EOF
    return 0
  fi
  local version
  version="$("${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}" --version 2>/dev/null || printf 'unknown')"
  printf '{"ok":true,"binary":"%s","version":"%s"}\n' \
    "${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}" "${version}"
}

# --- Verb-dispatch functions ---
# Each function:
#   - Reads named flags from "$@".
#   - Never accepts secrets in argv (uses --secret-stdin pattern).
#   - Emits zero-or-more streaming JSON lines to stdout.
#   - Returns 41 if it cannot handle the op (defensive — router shouldn't route
#     here, but the guard is cheap).

tool_open() {
  "${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}" open "$@"
}

tool_click() {
  "${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}" click "$@"
}

tool_fill() {
  "${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}" fill "$@"
}

tool_snapshot() {
  "${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}" snapshot "$@"
}

tool_inspect() {
  "${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}" inspect "$@"
}

tool_audit() {
  return 41
}

tool_extract() {
  return 41
}

tool_eval() {
  "${_BROWSER_TOOL_PLAYWRIGHT_CLI_BIN}" eval "$@"
}
