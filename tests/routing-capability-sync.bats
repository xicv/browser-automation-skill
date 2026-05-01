load helpers

# This test enforces spec §4.5: every routing rule must name a tool whose
# tool_capabilities() declares support for the verb the rule targets.
# A mismatch is a CI-failing drift signal.

@test "routing-capability-sync: every rule's tool declares support for the verb it targets" {
  for verb in open click fill snapshot inspect; do
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
  for verb in open click fill snapshot inspect; do
    printf '%s' "${declared}" | jq -e --arg v "${verb}" '.verbs | has($v)' >/dev/null \
      || fail "rule_default_navigation routes verb=${verb} to playwright-cli, but playwright-cli does not declare it"
  done
}
