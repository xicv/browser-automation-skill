load helpers

# This test enforces spec §4.5: every routing rule must name a tool whose
# tool_capabilities() declares support for the verb the rule targets.
# A mismatch is a CI-failing drift signal.

@test "routing-capability-sync: every rule's tool declares support for the verb it targets" {
  for verb in open click fill snapshot audit inspect extract; do
    run bash -c "
      source '${LIB_DIR}/common.sh'; init_paths
      source '${LIB_DIR}/router.sh'
      pick_tool ${verb}
    "
    [ "${status}" = "0" ] || fail "router refused to pick a tool for verb=${verb} (drift?)"
  done
}

@test "routing-capability-sync: rule_default_navigation never echoes a tool that lacks the verb" {
  declared="$(adapter_run_query playwright-cli tool_capabilities)"
  for verb in open click fill snapshot; do
    printf '%s' "${declared}" | jq -e --arg v "${verb}" '.verbs | has($v)' >/dev/null \
      || fail "rule_default_navigation routes verb=${verb} to playwright-cli, but playwright-cli does not declare it"
  done
}

@test "routing-capability-sync (8-2-i): rule_scrape_flag routes to a tool that declares verb=extract" {
  # Drift check: the new --scrape rule names obscura; obscura must declare
  # extract in tool_capabilities (otherwise the capability filter rejects
  # and the rule silently fails over).
  declared="$(adapter_run_query obscura tool_capabilities)"
  printf '%s' "${declared}" | jq -e '.verbs | has("extract")' >/dev/null \
    || fail "rule_scrape_flag routes verb=extract to obscura, but obscura does not declare extract"
}

@test "routing-capability-sync (8-2-i): pick_tool extract --scrape resolves cleanly (rule + capability both green)" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool extract --scrape https://example.com
  "
  [ "${status}" = "0" ] || fail "router refused to pick a tool for extract --scrape (drift?)"
  printf '%s' "${output}" | grep -q obscura || fail "expected obscura, got ${output}"
}

@test "routing-capability-sync (8-2-i): pick_tool extract --stealth resolves cleanly" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/router.sh'
    pick_tool extract --stealth https://example.com
  "
  [ "${status}" = "0" ] || fail "router refused to pick a tool for extract --stealth (drift?)"
  printf '%s' "${output}" | grep -q obscura || fail "expected obscura, got ${output}"
}
