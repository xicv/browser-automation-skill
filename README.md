# browser-automation-skill

A [Claude Code](https://claude.com/claude-code) skill for driving real browsers from an LLM. Routes tasks across four tools — Chrome DevTools MCP, Playwright CLI, the Playwright lib, and Obscura — and keeps every credential strictly local under `$HOME/.browser-skill/`.

> **Status:** Phase 1 (foundation). The verb that ships in this phase is `doctor`. Subsequent phases add `add-site`, `login`, `inspect`, `verify`, `audit`, `extract`, `flow run/record`, `replay`, `report`, and the credential vault.

## Security at a glance

- Credentials are on disk only at `$HOME/.browser-skill/` (mode 0700).
- Credentials never appear on argv, in `ps`, in git, or in the Claude transcript.
- `.gitignore` blocks every credential / session / capture pattern from the repo.
- `.githooks/pre-commit` rejects any staged file or diff that looks like a credential.
- See `SECURITY.md` for the full threat model.

## Requirements

- bash ≥ 4 (`brew install bash` on macOS — the system bash 3.2 is too old)
- `jq`
- `python3`
- `bats-core` (for tests; `brew install bats-core`)

## Install

### Personal (one machine, all your projects)

```bash
git clone https://github.com/xicv/browser-automation-skill ~/Projects/browser-automation-skill
cd ~/Projects/browser-automation-skill
./install.sh --with-hooks
```

### Verify (in Claude Code)

```
/browser doctor
```

Expected: exit 0; final line is a JSON summary with `"status":"ok"`.

## Uninstall

```bash
./uninstall.sh
```

Removes the `~/.claude/skills/browser-automation-skill` symlink. State at `~/.browser-skill/` is preserved by default.

## Layout

```
install.sh              # preflight + state dir + symlink + (opt) hooks
uninstall.sh            # remove symlink
SKILL.md                # Claude Code skill manifest (source of truth)
SECURITY.md             # threat model + disclosure
.gitignore              # blocks credential / profile patterns
.githooks/pre-commit    # credential-leak blocker
scripts/
  browser-doctor.sh     # the only verb in Phase 1
  install-git-hooks.sh
  lib/
    common.sh           # paths, exit codes, logging, summary writer, home resolver
tests/                  # bats — runs in <30s
```

## Roadmap

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for the design and `docs/superpowers/plans/` for executable plans.
