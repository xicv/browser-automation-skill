# Phase 6 part 6 — `upload` verb (file upload with path security)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Fill `<input type=file>` by ref + path. Stateful via daemon. Path validated bash-side BEFORE forwarding to MCP — protects against agent-misdirection attacks where a webpage tries to coerce uploading SSH keys / `.env` / credentials.

**Branch:** `feature/phase-06-part-6-upload`
**Tag:** `v0.27.0-phase-06-part-6-upload`.

---

## Threat model

**Attacker:** webpage instructions Claude reads (e.g. via `inspect`, captured in chat).

**Goal:** trick the agent into uploading sensitive files from disk to the attacker's server.

**Mitigations:**
1. Block obvious sensitive patterns by default. SSH keys, AWS credentials, `.env`, anything named `*credentials*` or `*private_key*` or `id_rsa*`. Reject with EXIT_USAGE_ERROR + clear hint.
2. Require explicit `--allow-sensitive` ack to override. Real use cases (e.g. uploading a GPG key to keybase.io) need an opt-in path; not blocking outright.
3. Resolve symlinks via `realpath` so `~/safe-file -> /etc/shadow` doesn't slip through pattern checks.
4. Validate file-exists + regular-file + readable. Catches typos + exotic device-file paths.

---

## Surface

```
bash scripts/browser-upload.sh --ref e3 --path ~/Downloads/photo.jpg
bash scripts/browser-upload.sh --ref e3 --path ~/.gnupg/exported-key.asc --allow-sensitive
```

Stateful — daemon required. Without daemon → exit 41 with hint.

---

## File Structure

### New
- `scripts/browser-upload.sh` — verb script with path security validation.
- `tests/browser-upload.bats` — 12 cases including security-path coverage.
- `docs/superpowers/plans/2026-05-05-phase-06-part-6-upload.md` — this plan.

### Modified
- `scripts/lib/router.sh` — `rule_upload_default` slotted after `rule_drag_default`.
- `scripts/lib/tool/chrome-devtools-mcp.sh` — `upload` capability + `tool_upload` dispatcher.
- `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — `upload` 2-arg shape (`upload <ref> <path>`); daemon dispatch case `'upload'` → MCP `upload_file`.
- `tests/stubs/mcp-server-stub.mjs` — `upload_file` handler.
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+2) — daemon happy + no-daemon.
- `SKILL.md` — auto-regenerated tools table.
- `CHANGELOG.md` — Phase 6 part 6 subsection (with security note).

---

## Test approach

`tests/browser-upload.bats` 12 cases:
1-2. Missing flag rejects (--ref / --path).
3. Nonexistent path → not-exist error.
4. Directory → not-regular-file error.
5. Unreadable file → not-readable error (skips when running as root).
6-7. SSH key path / .env path → sensitive-pattern reject.
8. `--allow-sensitive` bypass via dry-run.
9-10. Ghost-tool / capability filter rejects.
11. Dry-run.
12. Router routing assertion.

Plus 2 daemon-e2e cases (happy + no-daemon).

---

## Tag + push

```
git tag v0.27.0-phase-06-part-6-upload
git push -u origin feature/phase-06-part-6-upload
git push origin v0.27.0-phase-06-part-6-upload
gh pr create --title "feat(phase-6-part-6): upload verb (file upload with path security)"
```
