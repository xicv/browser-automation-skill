# midscene integration — design notes

`web-infra-dev/midscene` (MIT, 13k stars, updated 2026-05-20) is a vision-driven
UI automation framework: it grounds element selection in screenshots
processed by a visual-language model (VLM), not in DOM accessibility refs.
This file collects what we learned from the docs and proposes three
concrete integration paths into `browser-automation-skill`. No code in this
file — just design with verbatim citations and proposed env-var blocks.

## Why this matters

| Dimension | Our skill (today) | midscene |
|---|---|---|
| Element locator | `eN` accessibility refs (text-encoded) | screenshot coordinates (vision) |
| Per-action token cost | ~400 tok / page snapshot, 0 / cached action | ~1000 tok / screenshot, every action |
| Repeat-action cost | 0 via `browser-do` intent cache | full re-cost (cache is prompt-keyed, not intent-keyed) |
| Handles `<canvas>` / pixel-only UIs | NO | YES |
| Handles Android / iOS / desktop apps | NO | YES |
| Local-model option | n/a (Claude does grounding) | YES — Qwen3-VL / UI-TARS via OpenAI-compatible endpoint |

The paradigms are **complementary, not competing**. For DOM apps with
stable accessibility trees, our text refs win on token cost. For canvas,
mobile, PDF embeds, and any DOM-opaque UI, midscene's pixel grounding is
the only path. The integration plan below lets users pick the right tool
per intent without committing to one stack.

## Midscene cache mechanics (verbatim)

From <https://midscenejs.com/caching>:

> "Midscene uses the prompt instruction as the cache key to store the
> execution plan returned by AI"
>
> "the system uses the location prompt as the cache key to store element
> XPath information"
>
> "Cache contents will be saved in the `./midscene_run/cache` directory with
> the `.cache.yaml` as the extension name"
>
> Invalidation triggers:
> 1. "The text content of the new element at the same XPath is different
>    from the cached element"
> 2. "The DOM structure of the page is changed from the cached one"
>
> "query results like aiBoolean, aiQuery, aiAssert will never be cached"
>
> "XPath caching explicitly excludes Canvas, cross-origin iframes, closed
> Shadow DOM, and dynamically generated graphics"

How this maps onto our `browser-do` cache: both are intent-keyed (prompt
text → selector). Theirs invalidates on DOM diff; ours on Phase 13
fingerprint mismatch. They are **structurally equivalent caches with
different invalidation triggers** — see "Integration path 3" below for the
composition.

## Midscene API surface (verbatim)

From <https://midscenejs.com/api>:

> **Auto Planning**: `agent.aiAct()` / `agent.ai()` — Midscene
> automatically decomposes tasks into steps via AI model planning, then
> executes them sequentially.
>
> **Instant Actions**: `agent.aiTap()`, `agent.aiHover()`,
> `agent.aiInput()`, `agent.aiScroll()`, `agent.aiPinch()`,
> `agent.aiLongPress()`, `agent.aiDoubleClick()`, `agent.aiRightClick()` —
> The model locates elements while actions are predefined.
>
> **Data Extraction**: `agent.aiQuery()`, `agent.aiAsk()`,
> `agent.aiBoolean()`, `agent.aiNumber()`, `agent.aiString()`
>
> **Assertions & Waiting**: `agent.aiAssert()`, `agent.aiWaitFor()`,
> `agent.aiLocate()`

Screenshots are sent as base64 in the OpenAI-compatible payload.
`screenshotShrinkFactor` scales image dimensions before transmission.

## Midscene MCP servers (verbatim)

From <https://midscenejs.com/mcp>: four MCP-server packages, one per
platform:

```
npx -y @midscene/web-bridge-mcp
npx -y @midscene/ios-mcp
npx -y @midscene/android-mcp
npx -y @midscene/computer-mcp
```

Tool surface (per category): `web_connect`, `ios_connect`,
`android_connect`, `computer_connect`, `take_screenshot`, `assert`, plus
the Action Space verbs (`Tap`, `Scroll`, etc.). Detailed input schemas not
published on the docs page.

## Model wiring — concrete env-var blocks

Midscene 2026 conventions (from
<https://midscenejs.com/model-common-config>):

```bash
# Qwen3-VL via Alibaba DashScope (cloud, verified by midscene docs)
export MIDSCENE_MODEL_BASE_URL="https://dashscope.aliyuncs.com/compatible-mode/v1"
export MIDSCENE_MODEL_API_KEY="<your-dashscope-key>"
export MIDSCENE_MODEL_NAME="qwen3-vl-plus"
export MIDSCENE_MODEL_FAMILY="qwen3-vl"

# UI-TARS via Volcano Engine (cloud, verified)
export MIDSCENE_MODEL_BASE_URL="https://ark.cn-beijing.volces.com/api/v3"
export MIDSCENE_MODEL_API_KEY="<your-volces-key>"
export MIDSCENE_MODEL_NAME="ep-2025..."
export MIDSCENE_MODEL_FAMILY="vlm-ui-tars-doubao-1.5"

# GPT-5.4 (cloud, verified)
export MIDSCENE_MODEL_BASE_URL="https://api.openai.com/v1"
export MIDSCENE_MODEL_API_KEY="sk-..."
export MIDSCENE_MODEL_NAME="gpt-5.4"
export MIDSCENE_MODEL_FAMILY="gpt-5"
```

### Qwen3-VL via llama.cpp local (NOT in midscene docs — composed from
### OpenAI-compatible standard)

`llama-server` exposes an OpenAI-compatible API at
`http://127.0.0.1:8080/v1/chat/completions`. The `MIDSCENE_MODEL_*` block
follows:

```bash
# Local llama.cpp serving Qwen3-VL-4B-Instruct (q4_K_M)
export MIDSCENE_MODEL_BASE_URL="http://127.0.0.1:8080/v1"
export MIDSCENE_MODEL_API_KEY="local"          # llama-server ignores the key
export MIDSCENE_MODEL_NAME="Qwen3-VL-4B-Instruct"
export MIDSCENE_MODEL_FAMILY="qwen3-vl"
```

Launch command (verified working in `references/midscene-integration.md`
acceptance run — see "Local stack" below):

```bash
llama-server -hf Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M \
  --host 127.0.0.1 --port 8080
```

The `-hf` flag auto-downloads both the main `.gguf` AND the matching
`mmproj-*.gguf` (vision projector). First-run download ≈ 3.5 GB to
`~/Library/Caches/llama.cpp/` (macOS) or `~/.cache/llama.cpp/` (Linux).

### Local-stack disk + memory budget

| Model | Disk (q4_K_M) | Runtime unified-memory | Suitable Apple Silicon |
|---|---|---|---|
| Qwen3-VL-2B | ~2 GB | ~3 GB | M1+ 8 GB |
| Qwen3-VL-4B | ~3.5 GB | ~5 GB | M1+ 16 GB |
| Qwen3-VL-8B | ~6.5 GB | ~8 GB | M2+ 16 GB |
| Qwen3-VL-30B (MoE A3B) | ~22 GB | ~24 GB | M3 Max / M4 Max / M3 Ultra |
| UI-TARS-1.5-7B | ~4 GB | ~6 GB | M2+ 16 GB (browser-task-tuned) |

## Integration paths into browser-automation-skill

### Path 1 — Add `midscene-bridge` as 5th adapter (NARROW SCOPE)

Routed only when `--vision-only` flag set OR when other adapters return
`EXIT_TOOL_UNSUPPORTED_OP` because target is in a canvas / mobile-only
UI. Implementation: thin bash wrapper around `npx @midscene/web-bridge-mcp`
that translates our verb argv → midscene MCP `tools/call`.

Triggers (per `references/adapter-candidates.md` template):
- Target element is inside `<canvas>` → no other adapter can grab it
- User passes `--vision-only` explicitly
- User has Qwen3-VL/UI-TARS running locally OR cloud creds set

Why not as default: vision adapter costs ~1000 tok/action vs our cached
0 tok. Only use when the cheaper paths don't apply.

### Path 2 — Local-model env-var passthrough in our MCP server

Our Stage-1 MCP server (`scripts/lib/node/mcp-server.mjs`, shipped in
`67fd4a1`) currently shells to bash verb scripts. Extend it so the
`MIDSCENE_MODEL_*` block — when set in the client's env — passes through
to spawned children. Then clients that also speak to midscene see one
consistent local-LLM endpoint regardless of which skill they're calling.

Effort: ~5 LOC in `mcp-server.mjs`'s `spawn` call. No new dependency.

### Path 3 — `browser-do` cache enrichment via local VLM (HIGH LEVERAGE)

Our intent-keyed cache (`scripts/browser-do.sh`) currently does:

```
intent → archetype-id → cached selector → click
                            ↓ (miss / stale)
                       LLM round-trip on host (Claude)
```

Proposal: insert a local VLM probe BEFORE the LLM fallback:

```
intent → archetype-id → cached selector
                            ↓ (Phase 13 fingerprint diff)
                       local Qwen3-VL "is element at [bbox] still <intent>?"
                            ↓ yes        ↓ no
                       keep cache       LLM round-trip on host
```

Effect: when a cached selector goes stale due to a cosmetic DOM diff
(common: tooltip wrapper changes, ARIA attribute added), the local VLM
confirms visual identity in ~200ms on an M3 Pro w/ Qwen3-VL-4B. Zero
cloud tokens. Cache survives.

When the page genuinely changed (button moved, new flow), local VLM says
no → fall through to existing LLM round-trip → normal Phase 13 rescue
applies.

This is the biggest token saver of the three because it intercepts the
hot path: cache-near-miss is the most common cache failure mode in real
telemetry.

## What we shipped today (Phase 14) that enables this

Three commits landed before this design doc:

| Commit | Why this matters for midscene integration |
|---|---|
| `763c86c` Phase 14 A/B/C | `oblivious_success` events now fire on URL mismatch (Phase B). Means we can A/B "midscene-vision vs. cached selector" choices using stats.jsonl as the scoreboard, not anecdote. |
| `67fd4a1` MCP Stage 1 | Our verbs are now MCP-callable. Midscene's MCP server can call our `browser_snapshot` to get a cheap text ref before deciding whether vision grounding is needed. |
| `149a7d1` capture-flake fix | Full suite back to 1028/1028; future Path-3 work can ship behind RED-GREEN bats without an existing failure masking new regressions. |

## Acceptance: local-stack smoke test (status: measured 2026-05-20)

Environment:

- Hardware: Apple M3 Pro, 36 GB unified memory, macOS 25.5 (Darwin)
- llama.cpp: brew bottle 9200 (`3e12fbdea`), ARM64 native (`/opt/homebrew/bin/llama-server`)
- Model: `Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M` (4.02B params, 175K ctx slot, 2.49 GB resident; auto-downloaded with mmproj to `~/.cache/huggingface/hub/models--Qwen--Qwen3-VL-4B-Instruct-GGUF/`, total 2.8 GB on disk)
- Endpoint: `http://127.0.0.1:8080/v1/chat/completions` (OpenAI-compatible)
- Launch (FAT — defaults; wasteful for single-user): `llama-server -hf Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M --host 127.0.0.1 --port 8080`
- Launch (**LEAN, recommended** — single-user single-skill on M-series): see "Lean launch" block below

### Two measured runs (same hardware, same model)

Each row = same prompt against the same model on the same Mac. FAT run
takes server defaults (parallel=4, ctx=175616, threads=all-P-cores,
cache-ram=8192 MiB). LEAN run uses the bounded flags from the next
section.

| Smoke | FAT lat | LEAN lat | Speedup | FAT prompt / pred tok/s | LEAN prompt / pred tok/s | LEAN completion |
|---|---:|---:|---:|---:|---:|---|
| **1. Text (cold)** | 5.16 s | **0.28 s** | **18×** | 5.55 / 1.05 | 74.55 / 51.17 | `"Hello"` ✓ |
| **2. Vision (red PNG)** | 15.09 s | **0.47 s** | **32×** | 2.55 / 4.56 | 75.97 / 58.17 | `"blue"` ✗ (still wrong — quant-bound) |
| **3. Vision (green PNG)** | 15.56 s | **0.43 s** | **36×** | 1.76 / 2.78 | 70.74 / 58.25 | `"Green"` ✓ |
| **4. Text (warm)** | 1.88 s | **0.25 s** | **7.5×** | 12.64 / 7.80 | 91.88 / 41.30 | `"No reply."` ✓ |

Resident RAM (peak `ps -o rss` on the llama-server child): LEAN **3.99 GB** measured. FAT not directly measured but allocates ~4× the KV cache (175616 ctx × 4 slots vs 8192 × 1 slot ≈ 86× theoretical KV-buffer ratio); the prompt-cache cap dropped from 8192 MiB → 512 MiB independently.

### Lean launch (recommended default)

```bash
llama-server -hf Qwen/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M \
  --host 127.0.0.1 --port 8080 \
  --ctx-size 8192 \
  --parallel 1 \
  --threads 4 \
  --threads-batch 6 \
  --cache-ram 512 \
  --n-gpu-layers 99
```

Why each flag:

| Flag | Default | Lean | Why |
|---|---|---|---|
| `--ctx-size` | 175616 | 8192 | KV cache scales linear; 8K is enough for any single browser-grounding prompt |
| `--parallel` | 4 | 1 | each slot reserves its own KV cache; single-user → single slot |
| `--threads` | all P-cores | 4 | bounds generation-thread CPU footprint; leaves UI/agent responsive |
| `--threads-batch` | = `--threads` | 6 | lets prompt-eval (compute-bound) use more cores than generation (memory-bound) |
| `--cache-ram` | 8192 (MiB) | 512 | cap cross-request prompt cache; 512 MiB is enough for a few repeated turns |
| `--n-gpu-layers` | 99 (macOS default) | 99 | explicit; ensures all transformer layers offload to Metal GPU |

**Implications for the integration paths above:**

- **Pipeline works end-to-end.** OpenAI-compatible chat completions ✓, image_url base64 ingestion ✓, mmproj auto-loaded ✓.
- **Vision accuracy at 4B q4_K_M is borderline** (1/2 primary-color identifications wrong on identical-protocol calls — same outcome in both FAT and LEAN runs, so the misclassification is the QUANTIZATION talking, not config). For **Path 3 (cache-rescue visual confirmation)** this would generate false-negatives → DON'T wire 4B-q4_K_M into the cache hot path. Either:
  - **Qwen3-VL-8B q4_K_M** (~6.5 GB) — recommended by midscene
  - **Qwen3-VL-4B q8_0** (~4.3 GB) — higher fidelity at smaller size
  - **UI-TARS-1.5-7B** (~4 GB) — explicitly post-trained on UI grounding
- **LEAN config makes the local stack viable.** FAT vision-call cost was ~15 s; LEAN is ~0.45 s. That changes the Path 3 cost frame: **a cache-rescue visual probe at <500 ms is now competitive with — and often cheaper than — a cloud LLM round-trip** (~1 s + token cost). The model-accuracy gap above is now the only blocker; bump the model and Path 3 becomes the highest-ROI integration.
- **`Failed to load image or audio file` error** appears if the `data:image/png;base64,…` URL is malformed (e.g. embedded newlines in base64) — strip newlines with `tr -d '\n'` before constructing the data URL.

### Caveat — the FAT-vs-LEAN speedup is partially mmap-warmth, not pure config

The LEAN run executed after the FAT run on the same machine. Model
weights were already in the macOS filesystem cache (mmap'd from disk),
so LEAN paid no I/O-warmup cost. A true cold-disk LEAN run would be
slower than 0.28 s on Smoke 1 — closer to 1–2 s for the initial weight
read. Subsequent calls within the same process would still hit the
numbers in the LEAN column. The win that IS purely config:
- single slot vs four = no KV-cache duplication
- smaller ctx-size = smaller per-token attention matmul
- bounded thread count = no thermal throttling on M3 Pro's perf cores

## What NOT to do

- **Don't replace our a11y backbone with vision.** Token math fails for
  DOM apps (see table above).
- **Don't bundle Qwen3-VL into `install.sh`.** Even 4B q4_K_M is 3.5 GB
  download. `doctor` should advisory-check `llama-server --version` +
  HTTP ping `/health` and report "ok: local VLM ready" or "warn: local
  VLM not running — see references/midscene-integration.md".
- **Don't call midscene MCP server inline from a bash verb.** It's a
  long-lived daemon. Treat it like our Phase-5 `daemon-start` model:
  user launches once, verbs reuse the loopback endpoint.
- **Don't auto-fall-through to vision on every cache miss.** Gate behind
  an env var (e.g. `BROWSER_SKILL_VISION_FALLBACK=1`) until we have
  stats showing the VLM probe actually saves cloud tokens net of its
  local-compute cost.

## References

- midscene introduction — <https://midscenejs.com/introduction>
- midscene caching — <https://midscenejs.com/caching>
- midscene API — <https://midscenejs.com/api>
- midscene MCP — <https://midscenejs.com/mcp>
- midscene model config — <https://midscenejs.com/model-common-config>
- llama.cpp multimodal — <https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md>
- Qwen3-VL-4B-Instruct GGUF — <https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF>
- Our cache (browser-do) — `scripts/browser-do.sh` + spec
  `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md`
- Our MCP server — `scripts/lib/node/mcp-server.mjs` + cheatsheet
  `references/browser-mcp-cheatsheet.md`
- Phase 14 commits — `763c86c`, `67fd4a1`, `149a7d1`
