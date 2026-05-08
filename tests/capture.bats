load helpers

# Phase 7 part 1-i: lib/capture.sh contract tests.
# Three functions: capture_init_dir / capture_start / capture_finish.
# Atomic NNN allocation via tmpfile + mv (no flock); single-process per run.

setup() {
  setup_temp_home
  init_paths
  source "${LIB_DIR}/capture.sh"
}
teardown() { teardown_temp_home; }

# ---------- capture_init_dir ----------

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
