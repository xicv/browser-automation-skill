# Security policy

## Threat model

This skill is for single-developer, local-machine use.

### In scope (we defend against)
- Credentials leaking via argv / `ps` / shell history / git / Claude transcript
- Captures (HARs / console / screenshots) leaking auth tokens (Phase 7 sanitization)
- Sessions injected into the wrong origin (Phase 5 origin binding)
- Accidental commits of any credential-shaped file

### Out of scope
- Malware on your machine
- Compromised macOS / Linux kernel
- OS keychain compromise
- Compromised upstream tool (Playwright, chrome-devtools-mcp, Obscura)
- Compromised npm / cargo dependency
- Targeted nation-state attacker

## Reporting vulnerabilities

Use GitHub Security Advisories (private disclosure path) for any vulnerability. Do **not** open a public issue for security bugs.

PGP key: (TBD on first release).

## Defense layers (full set lands across phases)

| Layer | Phase |
|---|---|
| Filesystem perms (0700/0600, umask 077) | 1 |
| Pre-commit credential-leak blocker | 1 |
| Process argv invariants (creds via stdin only) | 5 |
| Origin binding (sessions refuse cross-origin) | 5 |
| OS keychain backend | 5 |
| Typed-phrase confirmations for risky paths | 5 |
| Capture sanitization (HAR + console + DOM) | 7 |

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` §8 for the full security design.
