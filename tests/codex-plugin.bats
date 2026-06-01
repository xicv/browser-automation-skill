load helpers

@test "Codex plugin: manifest points at bundled skill and MCP server" {
  local manifest="${REPO_ROOT}/plugins/browser-automation-skill/.codex-plugin/plugin.json"
  [ -f "${manifest}" ]
  local pkg_version
  pkg_version="$(jq -r '.version' "${REPO_ROOT}/package.json")"
  jq -e --arg version "${pkg_version}" '
    .name == "browser-automation-skill"
    and .version == $version
    and .skills == "./skills/"
    and .mcpServers == "./.mcp.json"
    and .interface.displayName == "Browser Automation Skill"
    and (.interface.defaultPrompt | length) > 0
  ' "${manifest}" >/dev/null
}

@test "Codex plugin: bundled MCP server launches the npm MCP entrypoint" {
  local mcp="${REPO_ROOT}/plugins/browser-automation-skill/.mcp.json"
  [ -f "${mcp}" ]
  local pkg_version
  pkg_version="$(jq -r '.version' "${REPO_ROOT}/package.json")"
  jq -e --arg package "browser-automation-skill@${pkg_version}" '
    .mcpServers["browser-skill"].command == "npx"
    and .mcpServers["browser-skill"].args == ["-y", $package, "serve"]
    and .mcpServers["browser-skill"].startup_timeout_sec == 20
    and .mcpServers["browser-skill"].tool_timeout_sec == 60
  ' "${mcp}" >/dev/null
}

@test "Codex plugin: repo marketplace exposes the plugin wrapper" {
  local marketplace="${REPO_ROOT}/.agents/plugins/marketplace.json"
  [ -f "${marketplace}" ]
  jq -e '
    .name == "browser-automation-skill"
    and .plugins[0].name == "browser-automation-skill"
    and .plugins[0].source.source == "local"
    and .plugins[0].source.path == "./plugins/browser-automation-skill"
    and .plugins[0].policy.installation == "AVAILABLE"
    and .plugins[0].policy.authentication == "ON_INSTALL"
  ' "${marketplace}" >/dev/null
}

@test "Codex plugin: legacy-compatible marketplace exposes the plugin wrapper" {
  local marketplace="${REPO_ROOT}/.claude-plugin/marketplace.json"
  [ -f "${marketplace}" ]
  jq -e '
    .name == "browser-automation-skill"
    and .plugins[0].name == "browser-automation-skill"
    and .plugins[0].source == "./plugins/browser-automation-skill"
  ' "${marketplace}" >/dev/null
}

@test "Codex plugin: skill has Codex frontmatter and secret safety guidance" {
  local skill="${REPO_ROOT}/plugins/browser-automation-skill/skills/browser-automation-skill/SKILL.md"
  [ -f "${skill}" ]
  head -20 "${skill}" | grep -q '^name: browser-automation-skill$'
  head -20 "${skill}" | grep -q '^description: Drive real browsers from OpenAI Codex'
  grep -q 'Never pass passwords, API keys, tokens, or other secrets through MCP tool arguments' "${skill}"
}

@test "package.json: npm package includes Codex plugin assets" {
  local package_json="${REPO_ROOT}/package.json"
  jq -e '
    .files as $files
    | all([".agents/", ".claude-plugin/", "plugins/"][]; . as $item | $files | index($item))
  ' "${package_json}" >/dev/null
}
