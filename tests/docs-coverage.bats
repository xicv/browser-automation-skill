load helpers

# Hand-curated doc-content presence checks. Distinct from regenerate-docs.bats
# (which exercises the AUTOGEN tools table). These pin the hand-edited verb
# tables + sections in SKILL.md / README.md to prevent silent drift after
# new verbs ship. When a verb is added in code but its doc row is forgotten,
# CI fails here.

@test "SKILL.md verb table has migrate sub-mode rows (Phase 10)" {
  # Mirrors the flow/baseline row style: `| \`migrate check\` | ...`. The
  # parent verb is browser-migrate; rows use the short sub-mode label,
  # consistent with `flow run`, `baseline save`, etc.
  grep -qE '^\| .migrate check' "${REPO_ROOT}/SKILL.md" \
    || fail "SKILL.md verb tables do not include a 'migrate check' row (Phase 10 part 1-ii)"
  grep -qE '^\| .migrate run' "${REPO_ROOT}/SKILL.md" \
    || fail "SKILL.md verb tables do not include a 'migrate run' row"
}

@test "SKILL.md has a Migration & schema evolution section (Phase 10 docs)" {
  grep -q 'Migration & schema evolution' "${REPO_ROOT}/SKILL.md" \
    || fail "SKILL.md is missing 'Migration & schema evolution' section heading"
}

@test "SKILL.md verb count reflects current verbs (42, not the pre-Phase-10 41)" {
  ! grep -qE '(^|[^0-9])41 verbs' "${REPO_ROOT}/SKILL.md" \
    || fail "SKILL.md still says '41 verbs'; browser-migrate (Phase 10) bumps the count"
}

@test "README.md verb count reflects current verbs (42, not the pre-Phase-10 41)" {
  ! grep -qE '(^|[^0-9])41 verbs' "${REPO_ROOT}/README.md" \
    || fail "README.md still says '41 verbs'; browser-migrate (Phase 10) bumps the count"
}

# ---------- Stage 4: agent-workflow recipes ----------
# 4 tutorial-shaped recipes covering the full toolchain end-to-end. Drift
# guard: each recipe MUST exist + reference the canonical verb names.

@test "Stage 4: agent-workflows/README.md exists + indexes all 4 recipes" {
  local index="${REPO_ROOT}/references/recipes/agent-workflows/README.md"
  [ -f "${index}" ] || fail "agent-workflows/README.md is missing"
  grep -q 'login-then-scrape.md' "${index}" \
    || fail "index missing login-then-scrape link"
  grep -q 'incremental-pattern-discovery.md' "${index}" \
    || fail "index missing incremental-pattern-discovery link"
  grep -q 'flow-record-and-replay.md' "${index}" \
    || fail "index missing flow-record-and-replay link"
  grep -q 'cache-driven-bulk-operation.md' "${index}" \
    || fail "index missing cache-driven-bulk-operation link"
}

@test "Stage 4: all 4 agent-workflow recipes exist + are non-empty" {
  for recipe in login-then-scrape incremental-pattern-discovery \
                flow-record-and-replay cache-driven-bulk-operation; do
    local path="${REPO_ROOT}/references/recipes/agent-workflows/${recipe}.md"
    [ -f "${path}" ] || fail "${recipe}.md is missing"
    # Each recipe must have at minimum a Goal + Outcome statement.
    grep -q '^\*\*Goal:\*\*' "${path}" \
      || fail "${recipe}.md lacks **Goal:** statement"
    grep -q '^\*\*Outcome:\*\*' "${path}" \
      || fail "${recipe}.md lacks **Outcome:** statement"
  done
}

@test "Stage 4: recipes reference real verb names (drift guard)" {
  # If a verb is renamed, the recipes must update too. Pin a few canonical
  # references the workflows rely on.
  local dir="${REPO_ROOT}/references/recipes/agent-workflows"
  grep -q 'browser-add-site.sh'  "${dir}/login-then-scrape.md" \
    || fail "login-then-scrape.md missing reference to browser-add-site.sh"
  grep -q 'browser-do.sh propose' "${dir}/incremental-pattern-discovery.md" \
    || fail "incremental-pattern-discovery.md missing browser-do.sh propose reference"
  grep -q 'browser-flow.sh' "${dir}/flow-record-and-replay.md" \
    || fail "flow-record-and-replay.md missing browser-flow.sh reference"
  grep -q 'memory cache hit rate' "${dir}/cache-driven-bulk-operation.md" \
    || fail "cache-driven-bulk-operation.md missing doctor cache-hit-rate reference"
}
