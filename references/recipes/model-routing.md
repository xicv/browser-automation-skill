# Recipe: Model routing — three-tier strategy

When and how to route Claude model selection across the parent session, this skill, and (eventually) per-verb invocations. The default ships with `model: sonnet` + `effort: low` in `SKILL.md` frontmatter; this recipe explains why, when to override, and how to layer in `opusplan` / `/advisor` at the parent session level.

## When to use this recipe

Use this whenever:
- A user reports the skill seems to "make wrong choices" on complex flows (multi-step logins, ambiguous snapshots) — they may need to escalate from default Sonnet.
- Your session token bill on browser tasks is bigger than you'd like — verify the three-tier setup is in place.
- You're integrating this skill into a different host CLI (Codex, Cursor, Gemini CLI) — the model-routing primitives may differ.

Do NOT use this recipe for:
- Picking which Anthropic SDK to install. Model routing is consumer-side; the SDK is producer-side.
- Speed-of-response tuning. Use `effort:` (low/medium/high/xhigh/max), not `model:`, for that knob.

## The three tiers

| Tier | Where it lives | Default in this skill | What it controls |
|---|---|---|---|
| 1. Parent session | `/model` command, `~/.claude/settings.json::model`, env var `ANTHROPIC_MODEL` | (user's choice — recommended: `opusplan`) | The "thinking" model — used when Claude reasons about what verb to call, parses snapshots, plans next steps |
| 2. Skill turn | `model:` field in `SKILL.md` frontmatter | `sonnet` + `effort: low` | The "acting" model — used during the single turn that invokes the skill. Per-turn override; resumes Tier 1 on next prompt |
| 3. Per-verb (future) | (not yet supported) | n/a | Some verbs may need Opus reasoning (login flow auto-detect); most just shell out to bash |

## Tier 1: Parent session

### Recommended: `/model opusplan` (stable)

```bash
# In any Claude Code session:
/model opusplan

# Or persist as default in ~/.claude/settings.json:
{ "model": "opusplan" }
```

`opusplan` is a Claude Code built-in alias: **Opus during plan mode, Sonnet during execution mode**. Plan mode is entered with `shift+tab` or `/plan`; exited with `shift+tab` again. Plan-mode reasoning is where the heavy thinking happens (designing flows, deciding how to debug a failure, brainstorming a feature plan). Execution mode is where Claude calls bash, edits files, runs verbs — Sonnet is enough.

This is the **zero-risk** starting point. No beta header. No skill edits. Available everywhere Claude Code runs (Anthropic-direct, Bedrock, Vertex, Foundry — though `opus`/`sonnet` resolve to provider-pinned versions on third-party providers).

### Advanced: `/advisor` (experimental as of v2.1.x)

```bash
/advisor    # toggle in current session
```

`/advisor` is the Claude Code surface for the [Advisor Tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool). The session model becomes the **executor** (Sonnet 4.6 by default; can pair Haiku 4.5 too); during generation the executor consults an **advisor** model (Opus 4.7) mid-stream when it hits decision points.

Mechanism (per [Advisor Tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool)):
1. Executor decides to consult — emits `server_tool_use { name: "advisor", input: {} }`.
2. Anthropic server runs Opus inference with the full transcript (no client orchestration).
3. Advisor returns ~400-700 token plan (~1,400-1,800 with thinking).
4. Executor continues, advice in context.

Cost economics:
- Executor (Sonnet) generates the bulk of output → billed at Sonnet rate ($3/$15 per 1M).
- Advisor (Opus) generates only advice tokens, billed at Opus rate ($5/$25 per 1M).
- Internal Anthropic benchmarks: "Sonnet executor at medium effort + Opus advisor → intelligence comparable to Sonnet at default effort, at lower cost."

**Caveats:**
- Beta status. May change. May hit rate limits on the advisor sub-inference (`too_many_requests` error code; executor continues without the advice).
- Not yet on Bedrock/Vertex/Foundry — Anthropic-direct only.
- Advisor sub-inference doesn't stream — expect a pause when consultation fires.
- No built-in conv-level cap; if cost balloons, set `max_uses` per request or toggle `/advisor` off.

**When to add `/advisor`**: after `opusplan` proves out the cost-saving direction. If browser-automation flows show ad-hoc reasoning bottlenecks (Sonnet picking wrong refs, missing the right verb sequence), `/advisor` lets Sonnet ask Opus for a plan without paying full Opus rate for the whole turn.

## Tier 2: This skill's frontmatter

```yaml
---
name: browser-automation-skill
...
model: sonnet
effort: low
---
```

Per [Claude Code skills docs](https://code.claude.com/docs/en/skills): "The override applies for the rest of the current turn and is not saved to settings; the session model resumes on your next prompt."

So when a user (or Claude auto-loading) invokes the skill:
- Skill turn = Sonnet + low effort
- Next prompt = back to parent session model (Tier 1: opusplan or whatever the user set)

**Why Sonnet, not Haiku.** Haiku 4.5 is ~3× cheaper than Sonnet 4.6 but has noticeably less robustness on multi-step verb chaining (snapshot → pick `eN` ref → fill → submit). Browser-automation flows have enough orchestration that Sonnet earns its 3× over Haiku. If a specific user's flows are simple (single-step extracts, dry-run-only), they can override per-skill via `~/.claude/settings.json::skillOverrides` (not currently a documented field for model — file an issue if you need this).

**Why `effort: low`.** Effort is independent of model. Sonnet at `effort: low` saves tokens vs Sonnet at default effort, with minimal capability loss for pure verb-driving (no deep reasoning needed — Claude already planned in the parent turn). If a flow regresses, bump to `effort: medium`.

**Override escape-hatch.** When a session demands Opus reasoning during the skill turn (debugging a complex login flow that Sonnet keeps mishandling), the user can:

```bash
# Override for the rest of the session — `inherit` keeps the parent model
/model opus    # before invoking the skill
```

Or edit the skill's frontmatter to `model: inherit` permanently to disable the per-turn override (skill follows parent session model).

## Tier 3: Per-verb (deferred)

Not currently supported by Claude Code's frontmatter model. If different verbs in this skill needed different models (e.g. `login --interactive` wants Opus for form-shape detection; `snapshot` wants Haiku for pure screen-scrape), the workaround would be:

- Split the skill into N skills, each with its own `SKILL.md` + `model:` field. Path: every verb script becomes a tiny standalone skill.
- Or use `Agent` tool from inside the skill body to spawn a subagent with a different `model:` parameter.

Not worth the structural complexity until multiple users report it. Track as open follow-up.

## How to verify the routing is working

```bash
# In Claude Code:
/status              # shows current session model
/model               # opens picker — verify opusplan or your choice is selected
```

After invoking a skill verb (e.g. `/browser-automation-skill snapshot`), `/status` may show that the active model briefly flipped to Sonnet (depending on how Claude Code surfaces per-turn overrides). The `usage.iterations[]` array in the API response shows the breakdown if you're driving via SDK.

For cost-per-session tracking, `/cost` (when available) summarizes token spend by model.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Skill picks wrong `eN` ref repeatedly | Sonnet at `effort: low` undercutting on snapshot interpretation | Bump skill frontmatter to `effort: medium` or override session-side with `/model opus` |
| `/advisor` toggle fails with "too_many_requests" | Advisor rate-limited on Opus | Toggle `/advisor` off; rely on opusplan only. Or wait + retry. |
| `model: opusplan` in SKILL.md doesn't activate plan mode | opusplan is plan-mode-state-aware; skill turn doesn't enter plan mode by itself | Use `model: sonnet` (current default) — opusplan is a parent-session-level alias, not a skill-turn primitive |
| Cost still high after opusplan + skill model:sonnet | Most tokens going to non-skill turns (parent reasoning, file reads) | Profile with `/cost`; if parent-side dominates, that's where to optimize next |

## Recommended setup for new users

```
1. Run `claude update` to get v2.1.x (advisor support).
2. Run `/model opusplan` once — persists across sessions.
3. (Optional) Run `/advisor` to enable advisor consultation.
4. Use this skill — frontmatter already routes the skill turn to Sonnet + low effort.
5. Watch token usage via `/cost` over a few sessions; tune effort if needed.
```

## See also

- [Claude Code Model configuration (`opusplan`)](https://code.claude.com/docs/en/model-config)
- [Skills frontmatter reference (`model`/`effort`)](https://code.claude.com/docs/en/skills)
- [Advisor Tool — Claude API Docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool)
- [Anthropic API pricing](https://platform.claude.com/docs/en/about-claude/pricing)
- Sister recipes: [privacy-canary.md](privacy-canary.md), [path-security.md](path-security.md), [body-bytes-not-body.md](body-bytes-not-body.md)
