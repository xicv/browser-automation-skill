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

# tool_extract — Phase 8 part 1-ii (--scrape) + 1-iii (--stealth).
#
# Modes (router/verb selects via flags; mutually exclusive):
#   --scrape <url1> <url2> ... [--eval EXPR] [--concurrency N]
#       Wraps `obscura scrape u1 u2 ... --eval EXPR --format json`. Emits one
#       `scrape_url` event per URL on stdout (success or error shape from
#       obscura's per-result divergence in run_parallel_scrape).
#   --stealth <url> --eval EXPR
#       Wraps `obscura fetch <url> --stealth --eval EXPR`. Single URL.
#       --eval REQUIRED (without it, obscura fetch dumps full HTML — too large
#       for the streaming-event contract). Emits one `extract_stealth` event:
#       {event, url, eval, time_ms}. Adapter times the call (fetch doesn't
#       report time). `eval` always emitted as string (obscura fetch --eval
#       prints raw, not wrapped JSON; typed parsing deferred).
#   --selector / --eval (single URL, no --scrape / --stealth) — never supported
#       here; routed to chrome-devtools-mcp / playwright-cli.
#
# Returns:
#   0  on successful adapter call (per-URL event stream may include errors).
#   2  on USAGE_ERROR (empty URL list with --scrape; missing URL or --eval
#      with --stealth).
#   41 if no recognized mode OR mutually-exclusive modes selected.
tool_extract() {
  local mode_scrape=0 mode_stealth=0 eval_expr="" concurrency=""
  local urls=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --scrape)      mode_scrape=1; shift ;;
      --stealth)     mode_stealth=1; shift ;;
      --eval)        eval_expr="$2"; shift 2 ;;
      --concurrency) concurrency="$2"; shift 2 ;;
      --selector|--site|--tool|--dry-run|--raw)
        # Recognised skill flags not consumed by this adapter.
        case "$1" in
          --dry-run|--raw) shift ;;
          *)               shift 2 ;;
        esac
        ;;
      --*)
        # Unknown flag — passthrough to obscura would mask config drift; reject.
        return 41
        ;;
      *)             urls+=("$1"); shift ;;
    esac
  done

  # Mutually-exclusive mode selection.
  if [ "${mode_scrape}" = "1" ] && [ "${mode_stealth}" = "1" ]; then
    return 41
  fi

  if [ "${mode_scrape}" = "1" ]; then
    _tool_extract_scrape "${eval_expr}" "${concurrency}" "${urls[@]}"
    return $?
  fi

  if [ "${mode_stealth}" = "1" ]; then
    _tool_extract_stealth "${eval_expr}" "${urls[@]}"
    return $?
  fi

  # No recognised mode. Other one-shot extract paths route elsewhere.
  return 41
}

# _tool_extract_scrape EVAL_EXPR CONCURRENCY URLS...
# Internal helper — wraps `obscura scrape`.
_tool_extract_scrape() {
  local eval_expr="$1" concurrency="$2"
  shift 2
  local urls=("$@")

  if [ "${#urls[@]}" -eq 0 ]; then
    return 2
  fi

  # Canonical argv (sha256-of-argv must be stable for fixture-based stub):
  #   scrape <urls...> [--eval EXPR] [--concurrency N] --format json
  local args=("scrape" "${urls[@]}")
  [ -n "${eval_expr}" ]   && args+=(--eval "${eval_expr}")
  [ -n "${concurrency}" ] && args+=(--concurrency "${concurrency}")
  args+=(--format json)

  local raw
  if ! raw="$("${_BROWSER_TOOL_OBSCURA_BIN}" "${args[@]}" 2>/dev/null)"; then
    return 41
  fi

  # Reshape obscura's per-URL .results[] into one streaming event line per URL.
  # Direct jq pass-through preserves the eval field's JSON typing (string /
  # number / array / null / object — emit_event can't carry arbitrary JSON
  # values). Summary line built by browser-extract.sh via emit_summary.
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

# _tool_extract_stealth EVAL_EXPR URLS...
# Internal helper — wraps `obscura fetch <url> --stealth --eval EXPR`.
# Single URL (rejects 0 or ≥2). --eval required.
_tool_extract_stealth() {
  local eval_expr="$1"
  shift
  local urls=("$@")

  if [ "${#urls[@]}" -ne 1 ]; then
    return 2
  fi
  if [ -z "${eval_expr}" ]; then
    return 2
  fi
  local url="${urls[0]}"

  # Canonical argv: fetch <url> --stealth --eval EXPR
  local args=("fetch" "${url}" --stealth --eval "${eval_expr}")

  # No time_ms field (obscura fetch doesn't report timing; the verb-script's
  # summary already carries end-to-end duration_ms via SUMMARY_T0). Adapters
  # are leaves — don't source common.sh's now_ms; don't fabricate timing.
  local raw
  if ! raw="$("${_BROWSER_TOOL_OBSCURA_BIN}" "${args[@]}" 2>/dev/null)"; then
    return 41
  fi

  # obscura fetch --eval prints raw evaluated result (string unquoted; other
  # JSON-encoded). Strip trailing newline; emit as string. Typed parsing
  # deferred — callers needing typed results should JSON.stringify in EXPR.
  local eval_out
  eval_out="${raw%$'\n'}"

  jq -nc \
    --arg url "${url}" \
    --arg eval_val "${eval_out}" \
    '{event: "extract_stealth", url: $url, eval: $eval_val}'

  return 0
}
