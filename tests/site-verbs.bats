# tests/site-verbs.bats
load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/sites"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/sites"
}

teardown() { teardown_temp_home; }

@test "add-site: minimal --name + --url succeeds and writes default profile" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod-app --url https://app.example.com
  assert_status 0
  local profile="${BROWSER_SKILL_HOME}/sites/prod-app.json"
  [ -f "${profile}" ]
  [ "$(jq -r .name "${profile}")" = "prod-app" ]
  [ "$(jq -r .url "${profile}")" = "https://app.example.com" ]
  [ "$(jq -r .viewport.width "${profile}")" = "1280" ]
  [ "$(jq -r .viewport.height "${profile}")" = "800" ]
  [ "$(jq -r .schema_version "${profile}")" = "1" ]
  # Final line is the JSON summary.
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "add-site" and .status == "ok"' >/dev/null
}

@test "add-site: --viewport WxH overrides default" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name x --url https://x.test --viewport 1920x1080
  assert_status 0
  [ "$(jq -r .viewport.width  "${BROWSER_SKILL_HOME}/sites/x.json")" = "1920" ]
  [ "$(jq -r .viewport.height "${BROWSER_SKILL_HOME}/sites/x.json")" = "1080" ]
}

@test "add-site: --label, --default-session, --default-tool stored verbatim" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod-app --url https://app.example.com \
    --label "Production app" --default-session prod-app--admin --default-tool playwright-cli
  assert_status 0
  local profile="${BROWSER_SKILL_HOME}/sites/prod-app.json"
  [ "$(jq -r .label             "${profile}")" = "Production app" ]
  [ "$(jq -r .default_session   "${profile}")" = "prod-app--admin" ]
  [ "$(jq -r .default_tool      "${profile}")" = "playwright-cli" ]
}

@test "add-site: rejects an existing site without --force (exit 2)" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://other.test
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "already exists"
}

@test "add-site: --force overwrites" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://other.test --force
  assert_status 0
  [ "$(jq -r .url "${BROWSER_SKILL_HOME}/sites/prod.json")" = "https://other.test" ]
}

@test "add-site: --dry-run writes nothing and reports planned action" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test --dry-run
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.would_run == true' >/dev/null
}

@test "add-site: rejects URL without scheme:// (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name x --url example.com
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "url must start with"
}

@test "add-site: rejects bad --viewport format (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name x --url https://x.test --viewport 1280
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "viewport"
}

@test "add-site: missing --name or --url is a usage error" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --url https://x.test
  assert_status "$EXIT_USAGE_ERROR"
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name x
  assert_status "$EXIT_USAGE_ERROR"
}

@test "add-site: rejects path-traversal in --name (security)" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name '../evil' --url https://x.test
  assert_status "$EXIT_USAGE_ERROR"
  # Ensure no file landed outside SITES_DIR.
  [ ! -e "${BROWSER_SKILL_HOME}/sites/../evil.json" ]
  [ ! -e "${BROWSER_SKILL_HOME}/sites/.json" ]
}

@test "add-site: rejects path-traversal in --default-session" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name x --url https://x.test --default-session '../evil'
  assert_status "$EXIT_USAGE_ERROR"
}

@test "list-sites: empty directory → status=ok and zero rows" {
  run bash "${SCRIPTS_DIR}/browser-list-sites.sh"
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "list-sites" and .status == "ok" and .count == 0' >/dev/null
}

@test "list-sites: lists registered sites with name + label + url" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name a --url https://a.test --label "App A" >/dev/null
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name b --url https://b.test --label "App B" >/dev/null
  run bash "${SCRIPTS_DIR}/browser-list-sites.sh"
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  [ "$(printf '%s' "${last_json}" | jq -r '.count')" = "2" ]
  [ "$(printf '%s' "${last_json}" | jq -r '.sites[0].name')"  = "a" ]
  [ "$(printf '%s' "${last_json}" | jq -r '.sites[0].url')"   = "https://a.test" ]
  [ "$(printf '%s' "${last_json}" | jq -r '.sites[0].label')" = "App A" ]
  [ "$(printf '%s' "${last_json}" | jq -r '.sites[1].name')"  = "b" ]
}

@test "show-site: prints profile JSON and a JSON summary" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test --label "Prod" >/dev/null
  run bash "${SCRIPTS_DIR}/browser-show-site.sh" --name prod
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "show-site" and .status == "ok" and .site == "prod"' >/dev/null
  [ "$(printf '%s' "${last_json}" | jq -r '.profile.url')" = "https://x.test" ]
}

@test "show-site: missing site exits 23 (SITE_NOT_FOUND)" {
  run bash "${SCRIPTS_DIR}/browser-show-site.sh" --name nope
  assert_status "$EXIT_SITE_NOT_FOUND"
}

@test "show-site: requires --name (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-show-site.sh"
  assert_status "$EXIT_USAGE_ERROR"
}

@test "remove-site: removes a registered site (typed-name confirmation via stdin)" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash -c "printf 'prod\n' | '${SCRIPTS_DIR}/browser-remove-site.sh' --name prod"
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
}

@test "remove-site: refuses on confirmation mismatch" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash -c "printf 'wrong\n' | '${SCRIPTS_DIR}/browser-remove-site.sh' --name prod"
  assert_status "$EXIT_USAGE_ERROR"
  [ -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
}

@test "remove-site: --yes-i-know skips the prompt" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-remove-site.sh" --name prod --yes-i-know
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
}

@test "remove-site: missing site exits 23" {
  run bash "${SCRIPTS_DIR}/browser-remove-site.sh" --name ghost --yes-i-know
  assert_status "$EXIT_SITE_NOT_FOUND"
}

@test "remove-site: --dry-run prints planned action and writes nothing" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-remove-site.sh" --name prod --dry-run
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
}

@test "use: --show prints empty when no current site set" {
  run bash "${SCRIPTS_DIR}/browser-use.sh" --show
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "use" and .status == "ok" and .current == null' >/dev/null
}

@test "use: --set NAME persists, --show then reports it" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-use.sh" --set prod
  assert_status 0
  [ "$(cat "${BROWSER_SKILL_HOME}/current")" = "prod" ]
  run bash "${SCRIPTS_DIR}/browser-use.sh" --show
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  [ "$(printf '%s' "${last_json}" | jq -r '.current')" = "prod" ]
}

@test "use: --set rejects an unknown site (exit 23)" {
  run bash "${SCRIPTS_DIR}/browser-use.sh" --set ghost
  assert_status "$EXIT_SITE_NOT_FOUND"
}

@test "use: --clear removes CURRENT_FILE" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  bash "${SCRIPTS_DIR}/browser-use.sh" --set prod >/dev/null
  run bash "${SCRIPTS_DIR}/browser-use.sh" --clear
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/current" ]
}

@test "use: requires exactly one of --set/--show/--clear (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-use.sh"
  assert_status "$EXIT_USAGE_ERROR"
}
