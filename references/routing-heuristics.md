# Routing heuristics and daily-job strategy

This reference explains how agents should choose between the skill's browser routes. It complements `scripts/lib/router.sh`, which is the executable source of truth for primitive adapter selection.

## Mental model

Choose the cheapest route that can complete the task **and** verify the outcome.

```text
known + repeatable          → cache or replay
simple + no secret          → MCP tool
stateful/sensitive          → local CLI verb
uncertain/debugging         → inspect/extract/audit + capture
novel + long-horizon + no-auth → delegate to Webwright/GLM
```

Daily browser jobs should get more deterministic over time. The first run may explore; the tenth run should mostly reuse stored sessions, cached selectors, flow replay, and assertions.

## Route ladder

| Task shape | First choice | Escalate when |
|---|---|---|
| Check install health, adapters, state dir, migrations | `browser-doctor.sh` | Missing adapter or migration warning needs setup |
| Register a site or select current site | site verbs | N/A |
| Login or use secrets | local CLI session/credential verbs | Never to MCP or delegation |
| Open/snapshot/click/fill/extract without secrets | MCP tools | Need full CLI options, capture history, or cached memory |
| Known repeated click/fill on a URL archetype | `browser-do.sh --intent ... --pattern ...` | Cache miss or repeated post-condition failure |
| Known multi-step workflow | `browser-flow.sh run` or `browser-replay.sh` | Page changed enough that replay fails |
| Debug a broken UI flow | `browser-inspect.sh`, `browser-extract.sh`, `browser-audit.sh` | Need manual or model-assisted re-resolution |
| Novel, no-auth, multi-step public web task | `browser-delegate.sh` if policy allows | Credentialed/destructive/repeatable tasks should stay local |

## Adapter routing principles

Primitive verbs are routed by `scripts/lib/router.sh`. The current priority is:

1. Session-bound operations route to `playwright-lib` when storage state is active.
2. Capture, console, network, Lighthouse, and performance work route to `chrome-devtools-mcp`.
3. Multi-URL scraping and stealth extraction route to `obscura` when requested.
4. Default navigation and simple interactions prefer the route that declares the needed capability and preserves state.
5. Explicit `--tool NAME` should be treated as an override, not a new default.

Keep route changes localized in the router. Do not hide route precedence in individual verb scripts.

## Verification policy

A driver-level success result is not enough for daily jobs. Add a post-condition when the job changes state or when correctness matters:

```bash
BROWSER_STATS_EXPECT_TYPE=text \
BROWSER_STATS_EXPECT_MATCH=include \
BROWSER_STATS_EXPECT_VALUE='Saved' \
  bash scripts/browser-click.sh --selector 'button.save'
```

Good post-conditions are stable business facts, not incidental DOM details:

- URL includes an expected route.
- Toast or heading contains expected text.
- Table row count changed as expected.
- Extracted JSON/text contains a known value.
- A console/network capture does not include a known error signature.

## Cache policy

Use the memory cache only when all three keys are meaningful:

- **site** — the same product/application surface;
- **pattern** — a stable URL archetype such as `/devices/:id`;
- **intent** — the business action, for example `click delete`, `open audit tab`, or `fill search`.

Do not cache one-off selectors, password fields, payment actions, or destructive flows without strong confirmations and assertions.

When `browser-stats` shows repeated `oblivious_success` for a selector, treat the cache as polluted. Re-record with a better selector or run `browser-stats prune --dry-run` before applying a disable.

## Delegation policy

Use Webwright/GLM delegation to save primary-agent context only when the task is:

- novel rather than already cached or replayable;
- no-auth and free of secrets;
- multi-step enough to justify offloading;
- non-destructive;
- allowed by `browser-delegate.sh config get`.

The delegate should return a compact result and artifact path. The primary agent should not stream the whole trajectory into its own context unless debugging requires it.

Recommended pattern:

```bash
bash scripts/browser-delegate.sh config get
bash scripts/browser-delegate.sh \
  --task 'Find public pricing limits and summarize them as a table' \
  --start-url 'https://example.com/pricing' \
  --max-steps 12
```

## Daily job hardening checklist

Before trusting a daily browser job:

- [ ] `browser-doctor.sh` passes or only reports understood optional adapter warnings.
- [ ] Credentials and sessions are local; no secrets are sent through MCP arguments.
- [ ] The job has at least one post-condition assertion.
- [ ] Captures are retained long enough for debugging but pruned by policy.
- [ ] Repeated actions use `browser-do` or a flow instead of re-discovering refs.
- [ ] `browser-stats report --pareto` is reviewed for failures, latency, and token/byte proxies.
- [ ] Any delegated route is no-auth, bounded, and produces a compact result.
