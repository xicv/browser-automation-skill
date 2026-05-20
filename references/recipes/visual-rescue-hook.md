# Recipe — visual-rescue hook (Path 3)

`browser-do.sh` exposes a hook seam BETWEEN Phase-13 fingerprint-rescue
failure and the cloud-LLM fall-through. The hook decides whether a cached
selector is still semantically the right target — typically by looking at
a screenshot through a local VLM. When the hook says yes, the cache is
preserved + no cloud-LLM round-trip happens.

## When this fires

```
cached selector + page fingerprint match    → 0 LLM tokens
  ↓ DOM diff detected
Phase-13 silent fingerprint rescue           → 0 LLM tokens
  ↓ rescue failed (no good selector candidate)
[HOOK FIRES HERE]   ← Path 3
  ↓ hook returns "yes" → keep cache, 0 cloud tokens
  ↓ hook returns "no" / unreachable → fall through
cloud LLM ref-resolution                     → 1 LLM round-trip
```

## Enabling the hook

Two env vars must be set when invoking `browser-do --intent ...`:

```bash
export BROWSER_SKILL_VISION_FALLBACK=1
export BROWSER_SKILL_VISUAL_RESCUE_CMD=/abs/path/to/your-hook.sh
chmod +x "${BROWSER_SKILL_VISUAL_RESCUE_CMD}"
```

If either is unset (or the hook isn't executable), the tier is skipped
silently and behaviour matches today's baseline.

## Hook contract

The hook is invoked with **three positional args**:

```bash
your-hook.sh SITE INTENT CACHED_SELECTOR
```

- `SITE` — registered site name (e.g. `prod-app`)
- `INTENT` — natural-language intent from the original `browser-do --intent` call
- `CACHED_SELECTOR` — the CSS selector that was retrieved from `~/.browser-skill/memory/<site>/archetypes/<id>.json` (the one Phase-13 rescue couldn't salvage)

The hook must write **exactly `yes` or `no` to stdout** (single line, no
JSON envelope). Any other output is treated as "no". Exit code:

- `0` + stdout `yes` → cache preserved; verb dispatch reports success
- `0` + stdout `no` → fall through to cloud LLM
- non-zero exit → fall through (treated as "unreachable")

Stderr is ignored by `browser-do`; use it for hook-internal logging.

## Reference implementation — llama.cpp + Qwen3-VL-4B

A minimum hook that screenshots the current page (via `browser-snapshot.sh`
+ `browser-inspect.sh --screenshot`) and asks a local Qwen3-VL through
`llama-server` is shown below. This is a SAMPLE — write your own to taste.

```bash
#!/usr/bin/env bash
# ~/.browser-skill/hooks/visual-rescue-llama.sh
set -euo pipefail
site="$1"; intent="$2"; selector="$3"

vlm_host="${BROWSER_SKILL_VLM_HOST:-127.0.0.1}"
vlm_port="${BROWSER_SKILL_VLM_PORT:-8080}"
endpoint="http://${vlm_host}:${vlm_port}/v1/chat/completions"

# Quick reachability gate — silent skip if VLM not running.
if ! curl -sfm 2 "http://${vlm_host}:${vlm_port}/health" >/dev/null; then
  printf 'no\n'
  exit 1
fi

# Take a transient screenshot via the inspect verb (Phase 7 captures dir).
# Find the most-recent screenshot file under captures/.
SCRIPTS_DIR="${BROWSER_SKILL_SCRIPTS_DIR:-${HOME}/.claude/skills/browser-automation-skill/scripts}"
bash "${SCRIPTS_DIR}/browser-inspect.sh" --site "${site}" --screenshot --capture \
  >/dev/null 2>&1 || { printf 'no\n'; exit 1; }
captures_dir="${BROWSER_SKILL_HOME:-${HOME}/.browser-skill}/captures"
latest_id="$(jq -r '.latest' "${captures_dir}/_index.json" 2>/dev/null)"
png_path="${captures_dir}/${latest_id}/inspect-screenshot.png"
[ -f "${png_path}" ] || { printf 'no\n'; exit 1; }

# Ask the VLM: yes/no probe.
b64="$(base64 -i "${png_path}" | tr -d '\n')"
prompt="The user wants to: '${intent}'. The cached element was at CSS selector '${selector}'. Looking at this page, is there still a target element that matches the intent? Answer with ONLY 'yes' or 'no'."

resp="$(curl -sS -m 30 "${endpoint}" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg img "data:image/png;base64,${b64}" --arg p "${prompt}" '
    {model:"q",max_tokens:5,messages:[{role:"user",content:[
      {type:"text",text:$p},
      {type:"image_url",image_url:{url:$img}}
    ]}]}')" 2>/dev/null)"

completion="$(printf '%s' "${resp}" | jq -r '.choices[0].message.content // ""' 2>/dev/null)"
case "${completion,,}" in
  *yes*) printf 'yes\n' ;;
  *)     printf 'no\n' ;;
esac
```

Smoke test the hook in isolation:

```bash
echo "site=prod-app intent='click submit' selector='button.submit'"
~/.browser-skill/hooks/visual-rescue-llama.sh prod-app 'click submit' 'button.submit'
# → yes / no
```

## Telemetry

When the hook reports "yes" and `browser-do` accepts the rescue:

- A `_kind:"visual_rescue"` event line appears on stdout (machine-readable)
- A separate event lands in `~/.browser-skill/memory/stats.jsonl` with
  `gen_ai_tool_name:"browser-do.visual_rescue"` and `rescued:true`. Run
  `browser-stats report --route browser-do` to see your visual-rescue rate.

When the hook reports "no" or fails, NO visual_rescue event is emitted
(the original Phase-13 cache_miss + fail_count path runs unchanged).

## Cost frame

Rough numbers from the Phase-14 bench session (M3 Pro + Qwen3-VL-4B-q4_K_M):

| Step | Latency | Cloud tokens |
|---|---:|---:|
| Screenshot via inspect | ~1.5 s | 0 |
| base64 + curl + VLM yes/no | ~0.4 s | 0 |
| **Path 3 total** | **~2 s** | **0** |
| Cloud LLM ref-resolution (alternative) | ~1 s | full prompt + response |

Path 3 wins when avoided cloud-LLM cost exceeds local latency cost. For
high-volume cache flows (your registered prod sites with repeat actions),
this is "always" — the 2 s pays off after one avoided LLM round-trip.

## Why a hook, not a built-in

The skill is intentionally agnostic about HOW the visual probe reasons —
some users will want screenshot-crop + Qwen3-VL, others UI-TARS-7B,
others a yes/no LLM-as-judge against a text snapshot. Hardcoding one
approach would close the design space. The hook contract lets each user
ship their preferred probe without forking the skill.

A built-in default probe is planned for a future release; this recipe
will become the canonical reference once it lands.
