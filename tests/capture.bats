load helpers

# Phase 7 part 1-i: lib/capture.sh contract tests.
# Three functions: capture_init_dir / capture_start / capture_finish.
# Atomic NNN allocation via tmpfile + mv (no flock); single-process per run.

setup() {
  setup_temp_home
  init_paths
  source "${LIB_DIR}/capture.sh"
  # Anchor wall-clock for age-threshold tests. Fixture timestamps in this file
  # are written relative to 2026-05-09T12:00:00Z (epoch 1778328000). Without
  # this override, the suite rots: any test using retention_days=N fails once
  # real-world calendar drifts past the seeded fixture date by more than N.
  export BROWSER_SKILL_CAPTURE_NOW_EPOCH=1778328000
}
teardown() {
  unset BROWSER_SKILL_CAPTURE_NOW_EPOCH
  teardown_temp_home
}

# ---------- capture_init_dir ----------

@test "_capture_now_epoch: returns BROWSER_SKILL_CAPTURE_NOW_EPOCH when set" {
  BROWSER_SKILL_CAPTURE_NOW_EPOCH=1234567890 result="$(_capture_now_epoch)"
  [ "${result}" = "1234567890" ] \
    || fail "expected 1234567890 from env override, got '${result}'"
}

@test "_capture_now_epoch: falls back to date +%s when override unset" {
  unset BROWSER_SKILL_CAPTURE_NOW_EPOCH
  local now
  now="$(_capture_now_epoch)"
  [[ "${now}" =~ ^[0-9]+$ ]] \
    || fail "expected integer epoch, got '${now}'"
  # Sanity floor: must be later than 2026-05-01 (epoch 1777680000).
  [ "${now}" -gt 1777680000 ] \
    || fail "epoch too small (${now}); date +%s broken?"
  # Restore the suite anchor for subsequent tests in this file.
  export BROWSER_SKILL_CAPTURE_NOW_EPOCH=1778328000
}

@test "capture_init_dir: creates captures dir with mode 0700 if missing" {
  [ ! -d "${CAPTURES_DIR}" ] || fail "precondition violated: dir already exists"
  capture_init_dir
  [ -d "${CAPTURES_DIR}" ] || fail "captures dir not created"
  perms="$(stat -c '%a' "${CAPTURES_DIR}" 2>/dev/null || stat -f '%Lp' "${CAPTURES_DIR}" 2>/dev/null)"
  [ "${perms}" = "700" ] || fail "expected mode 700, got ${perms}"
}

@test "capture_init_dir: idempotent (no-op if dir already exists)" {
  capture_init_dir
  capture_init_dir
  [ -d "${CAPTURES_DIR}" ] || fail "captures dir gone"
}

# ---------- capture_start ----------

@test "capture_start: allocates NNN=001 on first run; exports CAPTURE_ID + CAPTURE_DIR" {
  capture_start snapshot
  [ "${CAPTURE_ID}" = "001" ] || fail "expected CAPTURE_ID=001 got ${CAPTURE_ID}"
  [ "${CAPTURE_DIR}" = "${CAPTURES_DIR}/001" ] || fail "CAPTURE_DIR mismatch"
  [ -d "${CAPTURE_DIR}" ] || fail "capture dir not created"
}

@test "capture_start: zero-pads to 3 digits" {
  capture_start snapshot
  [[ "${CAPTURE_ID}" =~ ^[0-9]{3}$ ]] || fail "expected 3-digit padded id, got ${CAPTURE_ID}"
}

@test "capture_start: bumps to 002 on second run" {
  capture_start snapshot
  capture_start snapshot
  [ "${CAPTURE_ID}" = "002" ] || fail "expected CAPTURE_ID=002 got ${CAPTURE_ID}"
}

@test "capture_start: writes meta.json with required shape (status=in_progress)" {
  capture_start snapshot
  [ -f "${CAPTURE_DIR}/meta.json" ] || fail "meta.json not written"
  jq -e '.capture_id == "001"'                "${CAPTURE_DIR}/meta.json" >/dev/null
  jq -e '.verb == "snapshot"'                 "${CAPTURE_DIR}/meta.json" >/dev/null
  jq -e '.status == "in_progress"'            "${CAPTURE_DIR}/meta.json" >/dev/null
  jq -e '.schema_version == 1'                "${CAPTURE_DIR}/meta.json" >/dev/null
  jq -e '.started_at | type == "string"'      "${CAPTURE_DIR}/meta.json" >/dev/null
}

@test "capture_start: meta.json mode 0600, dir mode 0700" {
  capture_start snapshot
  dir_perms="$(stat -c '%a' "${CAPTURE_DIR}" 2>/dev/null || stat -f '%Lp' "${CAPTURE_DIR}" 2>/dev/null)"
  meta_perms="$(stat -c '%a' "${CAPTURE_DIR}/meta.json" 2>/dev/null || stat -f '%Lp' "${CAPTURE_DIR}/meta.json" 2>/dev/null)"
  [ "${dir_perms}" = "700" ]  || fail "expected dir mode 700, got ${dir_perms}"
  [ "${meta_perms}" = "600" ] || fail "expected meta mode 600, got ${meta_perms}"
}

# ---------- capture_finish ----------

@test "capture_finish: updates meta.json with status=ok + finished_at + total_bytes + files[]" {
  capture_start snapshot
  printf '{"snapshot":"data"}' > "${CAPTURE_DIR}/snapshot.json"
  capture_finish ok
  jq -e '.status == "ok"'                    "${CAPTURE_DIR}/meta.json" >/dev/null
  jq -e '.finished_at | type == "string"'    "${CAPTURE_DIR}/meta.json" >/dev/null
  jq -e '.total_bytes >= 19'                 "${CAPTURE_DIR}/meta.json" >/dev/null
  jq -e '.files | type == "array"'           "${CAPTURE_DIR}/meta.json" >/dev/null
  jq -e '.files | map(select(.name == "snapshot.json")) | length == 1' "${CAPTURE_DIR}/meta.json" >/dev/null
}

@test "capture_finish: status=error when explicitly passed" {
  capture_start snapshot
  capture_finish error
  jq -e '.status == "error"' "${CAPTURE_DIR}/meta.json" >/dev/null
}

@test "capture_finish: default status is ok when omitted" {
  capture_start snapshot
  capture_finish
  jq -e '.status == "ok"' "${CAPTURE_DIR}/meta.json" >/dev/null
}

@test "capture_finish: writes _index.json with latest, count, total_bytes" {
  capture_start snapshot
  printf 'x' > "${CAPTURE_DIR}/snapshot.json"
  capture_finish ok
  [ -f "${CAPTURES_DIR}/_index.json" ] || fail "_index.json not written"
  jq -e '.latest == "001"'             "${CAPTURES_DIR}/_index.json" >/dev/null
  jq -e '.count == 1'                  "${CAPTURES_DIR}/_index.json" >/dev/null
  jq -e '.next_id == 2'                "${CAPTURES_DIR}/_index.json" >/dev/null
  jq -e '.schema_version == 1'         "${CAPTURES_DIR}/_index.json" >/dev/null
}

@test "capture_start + capture_finish: cycle survives across two captures (latest=002, count=2)" {
  capture_start snapshot
  printf 'a' > "${CAPTURE_DIR}/snapshot.json"
  capture_finish ok
  capture_start snapshot
  printf 'bb' > "${CAPTURE_DIR}/snapshot.json"
  capture_finish ok
  jq -e '.latest == "002"' "${CAPTURES_DIR}/_index.json" >/dev/null
  jq -e '.count == 2'      "${CAPTURES_DIR}/_index.json" >/dev/null
  jq -e '.next_id == 3'    "${CAPTURES_DIR}/_index.json" >/dev/null
}

# ---------- Phase 7 part 1-iv: capture_finish [status] [sanitized] ----------

@test "capture_finish ok true: meta.sanitized = true" {
  capture_start inspect
  capture_finish ok true
  jq -e '.sanitized == true' "${CAPTURE_DIR}/meta.json" >/dev/null
}

@test "capture_finish ok false: meta.sanitized = false (audit flag)" {
  capture_start inspect
  capture_finish ok false
  jq -e '.sanitized == false' "${CAPTURE_DIR}/meta.json" >/dev/null
}

@test "capture_finish (default args): meta.sanitized = true" {
  capture_start snapshot
  capture_finish
  jq -e '.sanitized == true' "${CAPTURE_DIR}/meta.json" >/dev/null
}

# ---------- Phase 7 part 1-v: capture_prune ----------
#
# Test helpers — author captures with custom started_at + status fields by
# reaching directly into ${CAPTURE_DIR}/meta.json after capture_start.
# Bypassing capture_finish keeps the test fixture deterministic; in
# production, capture_finish writes started_at via _capture_iso_now.

_seed_config() {
  # $1 retention_count, $2 retention_days
  capture_init_dir
  printf '{"schema_version":1,"retention_days":%s,"retention_count":%s,"warn_at_pct":90}\n' "$2" "$1" \
    > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
}

_seed_capture() {
  # $1 NNN id, $2 started_at ISO, [$3 status (default ok)], [$4 is_baseline (default false)]
  local id="$1" started="$2" status="${3:-ok}" baseline="${4:-false}"
  mkdir -p "${CAPTURES_DIR}/${id}"
  chmod 700 "${CAPTURES_DIR}/${id}"
  jq -n --arg id "${id}" --arg started "${started}" --arg status "${status}" --argjson baseline "${baseline}" \
    '{capture_id: $id, verb: "snapshot", schema_version: 1, started_at: $started, status: $status, is_baseline: $baseline, sanitized: true}' \
    > "${CAPTURES_DIR}/${id}/meta.json"
  chmod 600 "${CAPTURES_DIR}/${id}/meta.json"
}

@test "capture_prune: prunes by count threshold (retention_count=2; 3 captures → 2)" {
  _seed_config 2 14
  _seed_capture "001" "2026-05-09T08:00:00Z"
  _seed_capture "002" "2026-05-09T09:00:00Z"
  _seed_capture "003" "2026-05-09T10:00:00Z"
  capture_prune
  [ ! -d "${CAPTURES_DIR}/001" ] || fail "001 should have been pruned (oldest)"
  [ -d "${CAPTURES_DIR}/002" ]   || fail "002 should have survived"
  [ -d "${CAPTURES_DIR}/003" ]   || fail "003 should have survived"
}

@test "capture_prune: prunes by age threshold (retention_days=7; 30-day-old capture pruned)" {
  _seed_config 500 7
  _seed_capture "001" "2026-04-09T00:00:00Z"  # 30 days before 2026-05-09
  _seed_capture "002" "2026-05-09T08:00:00Z"  # fresh
  capture_prune
  [ ! -d "${CAPTURES_DIR}/001" ] || fail "001 (30d old) should have been pruned"
  [ -d "${CAPTURES_DIR}/002" ]   || fail "002 (fresh) should have survived"
}

@test "capture_prune: no-op when under both thresholds" {
  _seed_config 10 14
  _seed_capture "001" "2026-05-09T08:00:00Z"
  _seed_capture "002" "2026-05-09T09:00:00Z"
  capture_prune
  [ -d "${CAPTURES_DIR}/001" ] || fail "001 should have survived (under threshold)"
  [ -d "${CAPTURES_DIR}/002" ] || fail "002 should have survived (under threshold)"
}

@test "capture_prune: idempotent (second call is no-op)" {
  _seed_config 2 14
  _seed_capture "001" "2026-05-09T08:00:00Z"
  _seed_capture "002" "2026-05-09T09:00:00Z"
  _seed_capture "003" "2026-05-09T10:00:00Z"
  capture_prune
  capture_prune
  # 002 + 003 should still exist; nothing else changed.
  [ ! -d "${CAPTURES_DIR}/001" ] || fail "001 should remain pruned"
  [ -d "${CAPTURES_DIR}/002" ]   || fail "002 should still exist"
  [ -d "${CAPTURES_DIR}/003" ]   || fail "003 should still exist"
}

@test "capture_prune: baseline-protection (is_baseline:true preserved even when oldest)" {
  _seed_config 2 14
  _seed_capture "001" "2026-05-09T08:00:00Z" "ok" "true"   # oldest BUT baseline
  _seed_capture "002" "2026-05-09T09:00:00Z"
  _seed_capture "003" "2026-05-09T10:00:00Z"
  capture_prune
  [ -d "${CAPTURES_DIR}/001" ]   || fail "001 (baseline) should NOT have been pruned"
  [ ! -d "${CAPTURES_DIR}/002" ] || fail "002 (oldest non-baseline) should have been pruned instead"
  [ -d "${CAPTURES_DIR}/003" ]   || fail "003 should have survived"
}

@test "capture_prune: in-flight-protection (status:in_progress preserved)" {
  _seed_config 1 14
  _seed_capture "001" "2026-05-09T08:00:00Z" "in_progress"
  _seed_capture "002" "2026-05-09T09:00:00Z" "ok"
  capture_prune
  [ -d "${CAPTURES_DIR}/001" ]   || fail "001 (in-flight) should NOT have been pruned"
  [ ! -d "${CAPTURES_DIR}/002" ] || fail "002 (oldest non-in-flight) should have been pruned instead"
}

@test "capture_prune: _index.json recomputed (count + latest correct after prune)" {
  _seed_config 2 14
  _seed_capture "001" "2026-05-09T08:00:00Z"
  _seed_capture "002" "2026-05-09T09:00:00Z"
  _seed_capture "003" "2026-05-09T10:00:00Z"
  # Seed _index with stale count to verify recompute.
  printf '{"schema_version":1,"next_id":4,"count":3,"latest":"003","total_bytes":0}\n' > "${CAPTURES_DIR}/_index.json"
  capture_prune
  jq -e '.count == 2'      "${CAPTURES_DIR}/_index.json" >/dev/null
  jq -e '.latest == "003"' "${CAPTURES_DIR}/_index.json" >/dev/null
  jq -e '.next_id == 4'    "${CAPTURES_DIR}/_index.json" >/dev/null
}

@test "capture_prune: missing config → defaults applied (no-op for tiny test set)" {
  capture_init_dir
  [ ! -f "${CONFIG_FILE}" ] || rm -f "${CONFIG_FILE}"
  _seed_capture "001" "2026-05-09T08:00:00Z"
  _seed_capture "002" "2026-05-09T09:00:00Z"
  capture_prune
  # Defaults retention_count=500, retention_days=14 — 2 captures fresh.
  [ -d "${CAPTURES_DIR}/001" ] || fail "001 should survive default thresholds"
  [ -d "${CAPTURES_DIR}/002" ] || fail "002 should survive default thresholds"
}
