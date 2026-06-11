# browser-delegate auth bridge design

Status: design only. Authenticated delegation is still disabled.

`browser-delegate` may eventually run logged-in tasks, but only by reusing a
validated Playwright `storageState`. It must never pass browser-skill passwords,
TOTP secrets, or credential backend payloads to Webwright.

## Non-negotiable invariants

- Auth is explicit: `browser-delegate` continues to refuse credentialed sites
  unless the user passes a future `--allow-auth` flag.
- Passwords never cross the bridge. The bridge reads only session
  `storageState`; it must not call `credential_get_secret`.
- The source session file under `$BROWSER_SKILL_HOME/sessions/` is never passed
  directly to Webwright. The bridge writes a one-run copy with mode `0600`.
- The bridge runs existing session checks first: site exists, session exists,
  origin matches the registered site URL, TTL is not expired, and auto-relogin
  is attempted in the parent skill process when available.
- Bridge files live outside stdout/stderr and are never printed in full. JSON
  summaries may say `auth_bridge:true`, site, and session name; they must not
  include cookies, localStorage, headers, or credential backend names.
- Delegated auth remains opt-in even when `.delegate.mode` is `auto`; auto
  delegation must not silently pick authenticated Webwright runs.

## Proposed CLI surface

```bash
browser-delegate \
  --task "Download the latest invoice PDF" \
  --start-url https://app.example.test/invoices \
  --site app \
  --as app--billing \
  --allow-auth
```

Rules:

- `--allow-auth` without `--site` is a usage error.
- `--site` that has stored credentials remains refused unless `--allow-auth`
  is present.
- `--as` follows existing verb semantics: explicit session wins; otherwise the
  site profile's `default_session` is used. Missing both means no auth bridge.
- `--dry-run --allow-auth` reports that an auth bridge would be used, but does
  not copy the session file and does not create a Webwright workspace.

## Bridge lifecycle

1. Parse `--allow-auth`, `--site`, and optional `--as`.
2. Resolve the session through the existing session path:
   `resolve_session_storage_state` or an equivalent helper that preserves its
   origin, TTL, and auto-relogin behavior.
3. Validate the selected storageState shape with the same checks as
   `session_save`.
4. Create a one-run auth bundle under
   `$BROWSER_SKILL_HOME/runtime/delegate-auth/<task-id>/` with mode `0700`.
5. Copy the storageState to `storage-state.json` with mode `0600`.
6. Create bridge metadata with non-secret fields only:
   `site`, `session`, `source_session_mtime`, `storage_state_sha256`,
   `created_at`, and `expires_in_hours`.
7. Launch Webwright with a bridge config that points to the copied
   `storage-state.json`.
8. Delete the auth bundle after the run by default, regardless of success or
   failure. A debug override may keep it, but must warn loudly.
9. Keep the normal delegate workspace under `$BROWSER_SKILL_HOME/delegate/`.
   That workspace can contain screenshots of logged-in pages, so privacy-canary
   scanning still runs before any result is surfaced.

## Webwright integration requirement

Current local Webwright does not expose a `storage_state_path` option in
`webwright.run.cli`. The bridge must not fake auth by asking the LLM to type
secrets into forms.

The preferred implementation is a Webwright environment option:

```yaml
environment:
  storage_state_path: /path/to/runtime/delegate-auth/<task-id>/storage-state.json
```

For `browser_mode: local_launch`, Webwright should pass that path to
Playwright's `browser.new_context(storage_state=...)` before opening
`start_url`. `local_persistent` and `local_cdp` modes are out of scope until
they have equivalent isolation guarantees.

If upstream Webwright has no such option when implementation starts, the first
implementation step is a small local Webwright patch or wrapper that adds it.
Do not implement a password-form replay workaround.

## Failure behavior

- Stored credentials present, no `--allow-auth`: `EXIT_BLOCKLIST_REJECTED`.
- `--allow-auth` without `--site`: `EXIT_USAGE_ERROR`.
- Site missing: `EXIT_SITE_NOT_FOUND`.
- Session missing, origin mismatch, expired TTL, or failed auto-relogin:
  `EXIT_SESSION_EXPIRED`.
- Webwright install lacks storage-state support: `EXIT_TOOL_UNSUPPORTED_OP`
  with a message naming `storage_state_path`.
- Privacy canary hit after an auth run: `EXIT_BLOCKLIST_REJECTED`; result
  withheld.

## Acceptance tests for implementation

1. Existing no-auth credential refusal tests stay green.
2. `--allow-auth --site app --as app--admin --dry-run` reports
   `auth_bridge_planned:true` and creates no auth bundle.
3. Auth run copies exactly the resolved storageState to a mode-`0600` bridge
   file, then removes the auth bundle after the run.
4. Expired TTL triggers the existing auto-relogin path before copying.
5. Origin mismatch refuses before any Webwright process is spawned.
6. Stderr, stdout, stats events, and delegate summaries contain no cookie or
   localStorage values.
7. The Webwright subprocess receives the bridge storage-state path via config,
   not argv containing secret material.
8. `browser-stats` marks authenticated delegate runs with `auth_bridge:true`
   without storing cookies.
9. `browser-doctor` reports whether the installed Webwright supports
   `storage_state_path`.
10. `.delegate.mode:auto` does not auto-select authenticated delegation.
