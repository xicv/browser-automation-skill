load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  init_paths

  # Defensive: stubs for keychain/libsecret so any creds-add invocations in
  # setup don't escape to real OS vault.
  export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
  export KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"
  export LIBSECRET_STUB_STORE="${TEST_HOME}/libsecret-stub.json"

  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://app.example.com >/dev/null 2>&1
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name staging --url https://stg.example.com >/dev/null 2>&1
}
teardown() { teardown_temp_home; }

run_list() { bash "${SCRIPTS_DIR}/browser-creds-list.sh" "$@"; }

_seed_cred() {
  # Helper: register a credential without going through creds-add (faster for
  # tests; bypasses smart backend select).
  local name="$1" site="$2" backend="${3:-plaintext}"
  local meta
  meta="$(jq -nc --arg n "${name}" --arg s "${site}" --arg b "${backend}" \
    '{schema_version:1, name:$n, site:$s, account:"a@b.c", backend:$b,
      auth_flow:"single-step-username-password",
      auto_relogin:true, totp_enabled:false, created_at:"2026-05-03T00:00:00Z"}')"
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_save '${name}' '${meta}'
  "
}

@test "creds-list: file exists and is executable" {
  [ -f "${SCRIPTS_DIR}/browser-creds-list.sh" ] || fail "verb missing"
  [ -x "${SCRIPTS_DIR}/browser-creds-list.sh" ] || fail "verb not executable"
}

@test "creds-list: empty state — count=0, status=empty" {
  out="$(run_list)"
  printf '%s' "${out}" | jq -e '.verb == "creds-list"' >/dev/null
  printf '%s' "${out}" | jq -e '.count == 0' >/dev/null
  printf '%s' "${out}" | jq -e '.status == "empty"' >/dev/null
  printf '%s' "${out}" | jq -e '.credentials | length == 0' >/dev/null
}

@test "creds-list: populated state — count + credentials array" {
  _seed_cred prod--admin prod plaintext
  _seed_cred prod--readonly prod plaintext
  _seed_cred staging--admin staging plaintext
  out="$(run_list)"
  printf '%s' "${out}" | jq -e '.count == 3' >/dev/null
  printf '%s' "${out}" | jq -e '.status == "ok"' >/dev/null
  printf '%s' "${out}" | jq -e '.credentials | length == 3' >/dev/null
  printf '%s' "${out}" | jq -e '.credentials | map(.credential) | sort == ["prod--admin","prod--readonly","staging--admin"]' >/dev/null
}

@test "creds-list: --site filter shows only matching credentials" {
  _seed_cred prod--admin prod plaintext
  _seed_cred prod--ci prod plaintext
  _seed_cred staging--admin staging plaintext
  out="$(run_list --site prod)"
  printf '%s' "${out}" | jq -e '.count == 2' >/dev/null
  printf '%s' "${out}" | jq -e '.why == "list-by-site"' >/dev/null
  printf '%s' "${out}" | jq -e '.site_filter == "prod"' >/dev/null
  printf '%s' "${out}" | jq -e '.credentials | map(.credential) | sort == ["prod--admin","prod--ci"]' >/dev/null
}

@test "creds-list: NEVER includes a 'secret' field on any row (privacy invariant)" {
  _seed_cred prod--admin prod plaintext
  printf 'sekret-do-not-leak-list' > "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret"
  chmod 600 "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret"
  out="$(run_list)"
  if printf '%s' "${out}" | grep -q 'sekret-do-not-leak-list'; then
    fail "creds-list output contains the secret value — PRIVACY LEAK"
  fi
  if printf '%s' "${out}" | jq -e '.credentials[] | has("secret")' >/dev/null 2>&1; then
    fail "creds-list row has a 'secret' key — PRIVACY LEAK"
  fi
}

@test "creds-list: includes site/account/backend/auto_relogin/totp_enabled in each row" {
  _seed_cred prod--admin prod libsecret
  out="$(run_list)"
  row="$(printf '%s' "${out}" | jq -c '.credentials[0]')"
  printf '%s' "${row}" | jq -e '.credential == "prod--admin"' >/dev/null
  printf '%s' "${row}" | jq -e '.site == "prod"' >/dev/null
  printf '%s' "${row}" | jq -e '.backend == "libsecret"' >/dev/null
  printf '%s' "${row}" | jq -e 'has("account") and has("auto_relogin") and has("totp_enabled") and has("created_at")' >/dev/null
}
