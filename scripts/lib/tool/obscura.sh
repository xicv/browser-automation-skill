# scripts/lib/tool/obscura.sh — Obscura tool adapter (shell only; verb-dispatch
# stubs land real-mode in 8-1-ii / 8-1-iii).
#
# Implements the Tool Adapter Extension Model contract from
# docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md §2.
#
# Identity: tool_metadata, tool_capabilities, tool_doctor_check
# Verb dispatch: tool_open, tool_click, tool_fill, tool_snapshot, tool_inspect,
#                tool_audit, tool_extract, tool_eval
#
# Obscura (https://github.com/h4ckf0r0day/obscura, Apache 2.0, Rust) ships in
# two modes:
#   1. Stateless one-shot CLI: `obscura fetch <url>` + `obscura scrape <urls...>`
#   2. CDP server daemon:      `obscura serve --port 9222`
#
# This adapter targets ONLY mode 1 — the unique lane vs incumbents (parallel
# scrape + stealth + 30/70 MB footprint). Mode 2 overlaps with playwright-lib's
# CDP transport and will land there via a future --cdp-endpoint flag, NOT here.
#
# Reachable via --tool=obscura only in 8-1-i (Path A "ship-without-promotion"
# per spec 2026-04-30 §4.4). Router promotion to default for --scrape /
# --stealth lands in a follow-up PR (8-2-i, Path B).
#
# Adapters are LEAVES — never source another adapter. Shared logic factors into
# scripts/lib/<concern>.sh (sibling to lib/tool/).

[ -n "${_BROWSER_TOOL_OBSCURA_LOADED:-}" ] && return 0
readonly _BROWSER_TOOL_OBSCURA_LOADED=1

# Required by spec 2026-05-01-token-efficient-adapter-output-design §8: every
# adapter sources output.sh so verb-dispatch emits JSON via emit_summary /
# emit_event rather than hand-rolled printf. Lint tier 3 enforces this.
# shellcheck source=../output.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../output.sh"

readonly _BROWSER_TOOL_OBSCURA_BIN="${OBSCURA_BIN:-obscura}"

# --- Identity functions (called by framework once or for queries) ---

tool_metadata() {
  cat <<'EOF'
{
  "name": "obscura",
  "abi_version": 1,
  "version_pin": "0.x",
  "cheatsheet_path": "references/obscura-cheatsheet.md",
  "install_hint": "download release from https://github.com/h4ckf0r0day/obscura/releases (no Chrome/Node required); keep obscura + obscura-worker side-by-side"
}
EOF
}

tool_capabilities() {
  # Only `extract` declared — obscura's unique lane is stateless fetch/scrape.
  # Stateful navigation (open/click/fill/snapshot) belongs to playwright-cli /
  # playwright-lib / chrome-devtools-mcp; declaring them here would let the
  # router fall back to obscura for verbs it can't actually serve.
  #
  # Flags array is advisory in v1 (per spec 2026-04-30 §2.1) — `--scrape` and
  # `--stealth` are listed for documentation; real flag plumbing lands in
  # 8-1-ii / 8-1-iii.
  cat <<'EOF'
{
  "verbs": {
    "extract": { "flags": ["--scrape", "--stealth", "--eval", "--selector"] }
  }
}
EOF
}

tool_doctor_check() {
  if ! command -v "${_BROWSER_TOOL_OBSCURA_BIN}" >/dev/null 2>&1; then
    cat <<EOF
{ "ok": false, "binary": "${_BROWSER_TOOL_OBSCURA_BIN}", "error": "not on PATH",
  "install_hint": "download release from https://github.com/h4ckf0r0day/obscura/releases (no Chrome/Node required); keep obscura + obscura-worker side-by-side" }
EOF
    return 0
  fi
  local version
  version="$("${_BROWSER_TOOL_OBSCURA_BIN}" --version 2>/dev/null || printf 'unknown')"
  printf '{"ok":true,"binary":"%s","version":"%s"}\n' \
    "${_BROWSER_TOOL_OBSCURA_BIN}" "${version}"
}

# --- Verb-dispatch functions ---
# Each function:
#   - Reads named flags from "$@".
#   - Never accepts secrets in argv (uses --secret-stdin pattern).
#   - Emits zero-or-more streaming JSON lines to stdout.
#   - Returns 41 if it cannot handle the op (defensive — router shouldn't route
#     here, but the guard is cheap).
#
# Phase 8 part 1-i: every verb returns 41. tool_extract becomes real-mode in
# 8-1-ii (--scrape; this PR) and 8-1-iii (--stealth). All other verbs stay 41
# forever — obscura is intentionally a one-shot extract-only adapter.

tool_open()     { return 41; }
tool_click()    { return 41; }
tool_fill()     { return 41; }
tool_snapshot() { return 41; }
tool_inspect()  { return 41; }
tool_audit()    { return 41; }
tool_eval()     { return 41; }

# tool_extract — Phase 8 part 1-ii.
#
# Modes (router/verb selects via flags):
#   --scrape <url1> <url2> ... [--eval EXPR] [--concurrency N]
#       Wraps `obscura scrape u1 u2 ... --eval EXPR --format json`. Emits one
#       `scrape_url` event per URL on stdout (success or error shape from
#       obscura's per-result divergence in run_parallel_scrape).
#   --stealth (single URL)         — deferred to 8-1-iii.
#   --selector / --eval (single URL, no --scrape) — never supported here;
#       routed to chrome-devtools-mcp / playwright-cli.
#
# Returns 0 if obscura ran (any URL succeeded OR all failed — the per-URL error
# events surface in the stream; verb-script normalizes overall status). Returns
# 2 on USAGE_ERROR (--scrape with no URLs). Returns 41 if no recognized mode.
tool_extract() {
  local mode_scrape=0 eval_expr="" concurrency=""
  local urls=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --scrape)      mode_scrape=1; shift ;;
      --eval)        eval_expr="$2"; shift 2 ;;
      --concurrency) concurrency="$2"; shift 2 ;;
      --stealth|--selector|--site|--tool|--dry-run|--raw)
        # Recognised skill flags that are NOT handled in 8-1-ii. --stealth lands
        # in 8-1-iii. Skip-with-arg-or-just-skip per flag shape.
        case "$1" in
          --stealth|--dry-run|--raw) shift ;;
          *)                          shift 2 ;;
        esac
        ;;
      --*)
        # Unknown flag — passthrough to obscura would mask config drift; reject.
        return 41
        ;;
      *)             urls+=("$1"); shift ;;
    esac
  done

  if [ "${mode_scrape}" = "0" ]; then
    # Other modes (single-URL eval, stealth) deferred — see header.
    return 41
  fi

  if [ "${#urls[@]}" -eq 0 ]; then
    return 2
  fi

  # Build obscura argv: scrape <urls...> [--eval EXPR] [--concurrency N] --format json.
  # Argv order is canonical for fixture-based stub lookup (sha256-of-argv).
  local args=("scrape" "${urls[@]}")
  [ -n "${eval_expr}" ]   && args+=(--eval "${eval_expr}")
  [ -n "${concurrency}" ] && args+=(--concurrency "${concurrency}")
  args+=(--format json)

  local raw
  if ! raw="$("${_BROWSER_TOOL_OBSCURA_BIN}" "${args[@]}" 2>/dev/null)"; then
    # obscura crashed or returned non-zero. The stub uses 41 for missing
    # fixtures; surface the same so the verb-script can route status properly.
    return 41
  fi

  # Reshape obscura's per-URL .results[] into one streaming event line per URL.
  # Direct jq pass-through preserves the eval field's JSON typing (it can be
  # string / number / array / null / object — emit_event can't carry arbitrary
  # JSON values, so the streaming events bypass it). The summary line is still
  # built by browser-extract.sh via emit_summary.
  #
  # Per-result shape divergence (success vs error) handled by jq's branching:
  #   - error result: {url, error, time_ms}
  #   - success result: {url, title, eval, time_ms} (drop .worker — internal)
  printf '%s' "${raw}" | jq -c '
    .results[] |
    {event: "scrape_url"} +
      if has("error") then
        {url, error, time_ms}
      else
        {url, title, eval, time_ms}
      end
  ' || return 41

  return 0
}
