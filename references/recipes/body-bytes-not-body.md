# Recipe: `body_bytes`, not `body`, in replies

When a verb ingests caller-supplied content (HTTP body, large blob, multi-line text), ship the **byte length** in the reply — not the content itself. Avoids re-emitting agent-supplied data into stdout / logs / terminal capture / Claude transcript.

## When to use this recipe

Use this whenever a verb takes content via `--content`, `--body`, `--data`, `--*-stdin`, or any flag that ingests bytes the agent typed and the verb forwards downstream. Already shipped:

- `scripts/browser-route.sh` + `scripts/lib/node/chrome-devtools-bridge.mjs` (Phase 6 part 7-ii) — `route fulfill --body` / `--body-stdin`. Reply has `body_bytes`, not `body`.
- `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` (fill case, line ~432) — defensively scrubs `text` from the reply before emitting (related: privacy-canary handles the stronger secrets case).

Phase 7 capture-pipeline candidates: any sanitizer-output reply that shows the agent how much got redacted.

Do NOT use this recipe for:
- Replies whose **shape requires** the content (e.g. `extract --selector` returns the matched element's textContent — that's the whole point of the verb). The contract is *return what was extracted*, not *return how many bytes were extracted*.
- Secret-bytes (passwords, tokens). Those want **zero** reflection — see `privacy-canary.md`. Even `body_bytes` could leak something via length-side-channel for short secrets.

## The pattern

```javascript
// WRONG — echo the body in the reply
return {
  verb: 'route',
  action: 'fulfill',
  pattern: msg.pattern,
  status: msg.status,
  body: msg.body,        // <-- agent-supplied content, now in stdout
  rule_count: routeRules.length,
};
```

```javascript
// RIGHT — ship a length contract
return {
  verb: 'route',
  action: 'fulfill',
  pattern: msg.pattern,
  fulfill_status: msg.status,
  body_bytes: Buffer.byteLength(msg.body, 'utf8'),
  rule_count: routeRules.length,
};
// body itself stays in the daemon's routeRules; never re-emitted.
```

Source of truth: `scripts/lib/node/chrome-devtools-bridge.mjs::case 'route'` (the fulfill branch).

## Why the agent doesn't need the body back

The agent **just sent** the body. They have it. The reply's job is to confirm:
- That the request was accepted (`status: 'ok'`).
- That it landed where intended (`pattern`, `rule_count`).
- That the bytes the daemon received match what they sent (`body_bytes`).

A length match is sufficient evidence that nothing got truncated by transport. If the agent suspects encoding corruption, they can `printf '%s' BODY | wc -c` and compare. They never needed the body echoed.

## Why echoing is actively bad

1. **Stdout is the Claude transcript.** Every echoed byte is a token the model rereads on the next turn. A 50KB JSON mock body bloats context for zero gain.
2. **Logs persist.** If the user pipes the verb to `tee log.txt` or runs under `script(1)`, the body lands on disk in plain text. The daemon's in-memory store is a deliberate scoping decision; echoing undoes it.
3. **Terminal-recording tools capture stdout.** Asciinema, screen recordings of demos, even `tmux` capture-pane all see whatever lands on stdout.
4. **Convention sets expectations.** Once one verb echoes content, the next maintainer assumes that's the contract and adds another. Establishing "we ship lengths, not content" as the norm prevents the drift.

## Why `Buffer.byteLength`, not `body.length`

```javascript
// WRONG — JS string length is code units, not bytes
body_bytes: msg.body.length
// '🔒'.length === 2 (UTF-16 surrogate pair)
// '🔒' as utf-8 is 4 bytes
```

```javascript
// RIGHT — count bytes, not code units
body_bytes: Buffer.byteLength(msg.body, 'utf8')
```

If the agent's `printf | wc -c` says 4 and the reply's `body_bytes` says 2, that looks like data loss when it's just a counting-units mismatch. Always count in the same unit the agent will count in (bytes, not chars).

Bash equivalent (for strings the bash verb script measures):

```bash
# WRONG — only correct for ASCII
body_bytes="${#body_inline}"

# RIGHT — measure bytes via wc
body_bytes="$(printf '%s' "${body_inline}" | wc -c | tr -d ' ')"
```

`scripts/browser-route.sh:107` uses `${#body_inline}` only for the dry-run / inline-body case where the bash side already knows the bytes won't surprise; the daemon-side authoritative count uses `Buffer.byteLength`. For new verbs, prefer `wc -c` bash-side.

## Defense in depth: also scrub upstream

The bridge daemon's `route` reply is one layer. The fill verb's similar concern (`scripts/lib/node/chrome-devtools-bridge.mjs:432`) shows the defensive-scrub layered idiom:

```javascript
const reply = await ipcCall({ verb: 'fill', ref, text });
// Defensive: scrub any echoed text from the reply before emitting.
if (reply && typeof reply === 'object') delete reply.text;
emitReply(reply);
```

Even if the daemon child accidentally puts `text` into the reply, the bridge strips it on the way out. **Two layers** because either layer can be edited carelessly; both wrong at the same time is the regression that ships.

## What about echoing for `--dry-run`?

Dry-run is the **one** justified case for surfacing the body — the agent asked "what would happen?" without committing. Even there, ship `body_bytes` plus an excerpt with explicit truncation, never the full body:

```bash
# dry-run summary
emit_summary verb=route ... \
             fulfill_status="${status_code}" \
             body_bytes="${body_bytes}" \
             body_excerpt="$(printf '%s' "${body_inline}" | head -c 80)" \
             body_truncated="$([ "${body_bytes}" -gt 80 ] && echo true || echo false)"
```

`browser-route.sh` doesn't ship the excerpt today. Add it in a follow-up if dry-run UX feedback asks for it.

## Checklist for any new content-ingesting verb

```
1. Reply object has `<thing>_bytes` (length), not `<thing>` (content).
2. Daemon-child stores the content in the slot it was meant for; reply
   surface is purely confirmation.
3. Use Buffer.byteLength (Node) or wc -c (bash) — never .length on strings.
4. If the verb routes through a bridge, add a defensive `delete reply.<thing>`
   on the way out (see fill verb precedent).
5. Test that asserts the byte-length contract: roundtrip a body with a known
   non-ASCII character; confirm body_bytes matches `printf | wc -c`.
6. NEVER echo the content even in error replies — error UX is the message
   string, not the offending payload.
```

## See also

- `scripts/lib/node/chrome-devtools-bridge.mjs::case 'route'` — fulfill branch.
- `scripts/lib/node/chrome-devtools-bridge.mjs:432` — fill defensive scrub.
- [Privacy canary recipe](privacy-canary.md) — stronger discipline for credential bytes.
- [Path security recipe](path-security.md) — sister pattern for filesystem inputs.
