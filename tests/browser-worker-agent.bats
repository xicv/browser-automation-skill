load helpers

# The browser-worker subagent isolates verbose browser output (snapshots, DOM,
# HAR, console, Lighthouse) in its own context so the caller's main thread stays
# lean. The PLUGIN copy (plugins/.../agents/browser-worker.md) is the shipped,
# tracked artifact end users get — tests treat it as canonical so they pass in a
# clean checkout/CI. The repo-local .claude/agents copy is a gitignored dogfooding
# convenience; when present it must stay byte-identical to the plugin copy.

PLUGIN_AGENT_REL="plugins/browser-automation-skill/agents/browser-worker.md"
LOCAL_AGENT_REL=".claude/agents/browser-worker.md"

@test "browser-worker: shipped plugin agent definition exists" {
  [ -f "${REPO_ROOT}/${PLUGIN_AGENT_REL}" ]
}

@test "browser-worker: repo-local dogfood copy, when present, is identical to the plugin copy" {
  if [ ! -f "${REPO_ROOT}/${LOCAL_AGENT_REL}" ]; then
    skip "repo-local .claude/agents copy absent (gitignored; expected in a clean checkout/CI)"
  fi
  diff "${REPO_ROOT}/${LOCAL_AGENT_REL}" "${REPO_ROOT}/${PLUGIN_AGENT_REL}"
}

@test "browser-worker: frontmatter names the agent and scopes its tools" {
  local agent="${REPO_ROOT}/${PLUGIN_AGENT_REL}"
  grep -q '^name: browser-worker$' "${agent}"
  # tool allowlist must grant the browser MCP server and bash, nothing implying Edit/Write
  grep -q '^tools:.*mcp__browser-skill' "${agent}"
  grep -q '^tools:.*Bash' "${agent}"
  # the skill is preloaded so the worker is self-contained
  grep -q '^  - browser-automation-skill$' "${agent}"
}

@test "browser-worker: enforces a compact return contract (no raw dumps)" {
  local agent="${REPO_ROOT}/${PLUGIN_AGENT_REL}"
  grep -qi 'Return contract' "${agent}"
  grep -q 'status: ok | partial | error' "${agent}"
  # must explicitly forbid pasting raw snapshots / HAR / Lighthouse back to caller
  grep -qi 'Do not.*paste raw' "${agent}"
}

@test "root SKILL.md: instructs subagent dispatch and allows the worker tool" {
  local skill="${REPO_ROOT}/SKILL.md"
  grep -q '## Context isolation' "${skill}"
  grep -q 'browser-worker' "${skill}"
  # the skill must be permitted to dispatch the worker
  grep -q 'allowed-tools:.*Agent(browser-worker)' "${skill}"
}

@test "Codex SKILL.md: documents context isolation for subagent-capable hosts" {
  local skill="${REPO_ROOT}/plugins/browser-automation-skill/skills/browser-automation-skill/SKILL.md"
  grep -q '## Context isolation' "${skill}"
  grep -qi 'browser-worker' "${skill}"
}
