# Recipe: Path security

For any verb that takes a `--path` argument and forwards bytes from disk to a downstream tool (browser, MCP server, network upstream). Establishes the three guarantees the verb owes its caller, all enforced bash-side BEFORE the adapter dispatches.

## When to use this recipe

Use this whenever a verb accepts a filesystem path and acts on its contents. Already shipped: `scripts/browser-upload.sh` (Phase 6 part 6).

Phase 7 capture-pipeline work will reuse this for any verb that writes capture artifacts to a caller-specified location (`--out PATH`).

Do NOT use this recipe for:
- Paths the **framework owns** (e.g. `${BROWSER_SKILL_HOME}/sessions/<name>.json`). Trust boundary doesn't apply — those paths are constructed, not accepted.
- Read-only metadata commands (`show-site --name X` — name isn't a path).

## The three checks (in order)

```bash
# scripts/browser-<verb>.sh — paste-ready scaffold
[ -n "${path}" ] || die "${EXIT_USAGE_ERROR}" "<verb> requires --path PATH"

# 1. Existence + regular-file check.
#    Rejects: missing files, directories, devices, FIFOs, sockets.
if [ ! -e "${path}" ]; then
  die "${EXIT_USAGE_ERROR}" "<verb>: path does not exist: ${path}"
fi
if [ ! -f "${path}" ]; then
  die "${EXIT_USAGE_ERROR}" "<verb>: path is not a regular file: ${path}"
fi

# 2. Readability check (current user, current process).
if [ ! -r "${path}" ]; then
  die "${EXIT_USAGE_ERROR}" "<verb>: path is not readable by the current user: ${path}"
fi

# 3. Sensitive-pattern reject. Override with --allow-sensitive (typed ack).
if [ "${allow_sensitive}" -ne 1 ]; then
  case "${path}" in
    *.ssh/*|*/.ssh/*|*.aws/credentials|*/.aws/credentials|*/.env|*.env|\
    */credentials|*/credentials.json|*/secrets.json|*/private_key*|*/id_rsa*|\
    */id_ed25519*|*/id_ecdsa*)
      die "${EXIT_USAGE_ERROR}" "<verb>: path '${path}' matches a sensitive pattern; pass --allow-sensitive to override"
      ;;
  esac
fi

# 4. Realpath canonicalization (eliminates symlink games).
canonical_path="$(realpath "${path}" 2>/dev/null \
                  || readlink -f "${path}" 2>/dev/null \
                  || printf '%s' "${path}")"

# Forward the canonical path, not the user's input.
verb_argv+=(--path "${canonical_path}")
```

Source of truth: `scripts/browser-upload.sh:74-103`.

## Why each check exists

### Check 1 — `[ -f "${path}" ]`

```
WRONG — only check existence
[ -e "${path}" ] || die ...
# Passes for /dev/zero, /tmp/some-fifo, /etc — agent uploads garbage.
```

`-f` rejects directories, character/block devices, FIFOs, and sockets. The downstream tool was promised "a file's bytes"; an attempt to read `/dev/zero` would either hang the agent or upload an arbitrary number of zero bytes.

### Check 2 — `[ -r "${path}" ]`

Failing this check returns a clear UX error from the verb script. Skipping it pushes the failure down to the adapter, where the error message is whatever cdt-mcp / playwright happens to emit (often opaque, often surfaces a permissions dump).

### Check 3 — Sensitive-pattern reject

```
WRONG — trust the agent to know what they're doing
verb_argv+=(--path "${path}")  # forward whatever the agent typed
```

The agent can be tricked. A user pastes `--path ~/.ssh/id_rsa` into a browser-automation prompt and the agent obediently uploads it. Sensitive-pattern reject is the **default-deny**; `--allow-sensitive` is the typed acknowledgment that the agent saw the pattern and is uploading intentionally (e.g. uploading a GPG key to a keyserver).

The pattern list is intentionally short — it covers the **boring high-frequency** cases (SSH keys, AWS credentials, `.env` files). It is not a full DLP. Don't expand it to chase exotic filenames; that creates an arms race against tools-of-the-month.

### Check 4 — Realpath canonicalization

```
WRONG — forward agent input verbatim
verb_argv+=(--path "${path}")

# Then a symlink game beats the sensitive-pattern reject:
$ ln -s ~/.ssh/id_rsa /tmp/innocent.txt
$ verb --path /tmp/innocent.txt   # passes step 3 (path doesn't match patterns)
                                  # but actually uploads the SSH key
```

`realpath` resolves the symlink; the canonical path becomes `~/.ssh/id_rsa`, which the sensitive-pattern check would have caught — but that check already ran. Two correct orderings exist:

- **Resolve THEN check** (safer; resolution can't be skipped). Order in the recipe is "check then resolve" because that's how `browser-upload.sh` shipped; both work, but resolve-first is what to write next time.
- **Check then resolve, then re-check** (paranoid). Reasonable if you're worried about TOCTOU between the two operations.

Cross-platform fallback: macOS pre-Xcode-11 lacks `readlink -f` and may lack `realpath`. The chain `realpath || readlink -f || printf '%s'` gracefully degrades to verbatim path on the rare platform that has neither — at the cost of skipping symlink resolution on that platform. CI exercises both GNU (Linux) and BSD (macOS) realpath paths.

## What's NOT this recipe's job

- **Encryption-at-rest of the file's contents.** That's a different layer (the user's filesystem, FileVault, LUKS, etc.).
- **Anti-malware scanning.** Verb is a thin transport, not a security product.
- **Quarantining files after upload.** Out of scope; the user owns the file.
- **Sandboxing the downstream tool.** That's the adapter's concern — sensitive-pattern reject + realpath stops *accidental* exfil; defense against a hostile downstream tool is the wrong threat model for this layer.

## Test surface (already shipped for upload, copy for new verbs)

`tests/browser-upload.bats` cases worth porting:
- Path doesn't exist → `EXIT_USAGE_ERROR`.
- Path is a directory → `EXIT_USAGE_ERROR`.
- Path matches `~/.ssh/id_rsa` pattern → `EXIT_USAGE_ERROR` mentioning sensitive.
- Same path with `--allow-sensitive` → success (dry-run).
- Symlink-to-sensitive resolved by realpath → still rejected.
- Symlink-to-innocent resolved by realpath → success, canonical path forwarded.

## Checklist for any new path-accepting verb

```
1. Verb takes --path PATH and (if writes) maybe --out PATH.
2. Add --allow-sensitive flag (default 0; typed ack).
3. Inline the four-step block from this recipe between argv parsing and
   adapter dispatch. Replace `<verb>` with the verb name in error strings.
4. Forward the CANONICAL path (post-realpath), not the user's input.
5. Test cases: missing / dir / unreadable / sensitive-rejected /
   sensitive-allowed / symlink-to-sensitive / symlink-to-innocent.
6. CHANGELOG entry with [security] tag if this is a new attack surface.
```

## See also

- `scripts/browser-upload.sh:74-103` — the source-of-truth implementation.
- `tests/browser-upload.bats` — test cases to port.
- [Privacy canary recipe](privacy-canary.md) — sister pattern for credential bytes.
- [Body-bytes-not-body recipe](body-bytes-not-body.md) — sister pattern for content bodies.
