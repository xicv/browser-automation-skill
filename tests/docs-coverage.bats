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
