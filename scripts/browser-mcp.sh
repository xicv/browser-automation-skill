#!/usr/bin/env bash
# scripts/browser-mcp.sh — launch the MCP server that exposes browser-skill
# verbs as MCP tools (stdio JSON-RPC NDJSON, protocol version 2024-11-05).
#
# Usage:
#   bash scripts/browser-mcp.sh serve         # default; reads JSON-RPC on stdin
#   bash scripts/browser-mcp.sh --help        # usage
#
# Wire format: NDJSON. Each request/response is a single JSON object terminated
# by '\n'. Matches the framing of our existing chrome-devtools-bridge.mjs
# CLIENT so the codebase converges on one wire shape.
#
# Tools exposed (Stage 1): browser_open, browser_snapshot. See
# scripts/lib/node/mcp-server.mjs::TOOLS for the live registry.
#
# Phase 14 (Proposal 2 from midscene research): lets agent-browser / midscene
# / Stagehand / browser-use reuse our cache + telemetry + secrets vault
# without re-implementing them.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

BROWSER_SKILL_NODE_BIN="${BROWSER_SKILL_NODE_BIN:-node}"

case "${1:-serve}" in
  serve)
    if ! command -v "${BROWSER_SKILL_NODE_BIN}" >/dev/null 2>&1; then
      die "${EXIT_TOOL_MISSING}" \
        "node not on PATH (set BROWSER_SKILL_NODE_BIN to override)"
    fi
    exec "${BROWSER_SKILL_NODE_BIN}" "${SCRIPT_DIR}/lib/node/mcp-server.mjs"
    ;;
  --help|-h|help)
    cat <<'USAGE'
browser-mcp — MCP server for browser-skill verbs

Usage:
  bash scripts/browser-mcp.sh serve   # start JSON-RPC server on stdio
  bash scripts/browser-mcp.sh --help  # this message

Tools exposed (Stage 1):
  browser_open      — open a URL
  browser_snapshot  — capture eN-indexed accessibility snapshot

Protocol: MCP 2024-11-05, NDJSON over stdio. Spawn this server from any
MCP-capable client (Claude Code, Continue, Cline, agent-browser, midscene,
etc.) to drive our cache + telemetry without re-implementing it.

Smoke test (manual):
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | bash scripts/browser-mcp.sh serve
USAGE
    exit 0
    ;;
  *)
    die "${EXIT_USAGE_ERROR}" "unknown subcommand '${1}' — see --help"
    ;;
esac
