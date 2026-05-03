load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  init_paths

  export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"
  export KEYCHAIN_STUB_STORE="${TEST_HOME}/keychain-stub.json"
  export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"
  export LIBSECRET_STUB_STORE="${TEST_HOME}/libsecret-stub.json"
}
teardown() { teardown_temp_home; }

run_show() { bash "${SCRIPTS_DIR}/browser-creds-show.sh" "$@"; }

_seed_cred() {
  local name="$1" site="${2:-prod}" backend="${3:-plaintext}"
  local meta
  meta="$(jq -nc --arg n "${name}" --arg s "${site}" --arg b "${backend}" \
    '{schema_version:1, name:$n, site:$s, account:"alice@example.com", backend:$b,
      auth_flow:"single-step-username-password",
      auto_relogin:true, totp_enabled:false, created_at:"2026-05-03T00:00:00Z"}')"
  bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_save '${name}' '${meta}'
  "
}

@test "creds-show: file exists and is executable" {
  [ -f "${SCRIPTS_DIR}/browser-creds-show.sh" ] || fail "verb missing"
  [ -x "${SCRIPTS_DIR}/browser-creds-show.sh" ] || fail "verb not executable"
}

@test "creds-show: emits metadata for an existing credential" {
  _seed_cred prod--admin prod plaintext
  out="$(run_show --as prod--admin)"
  printf '%s' "${out}" | jq -e '.verb == "creds-show"' >/dev/null
  printf '%s' "${out}" | jq -e '.status == "ok"' >/dev/null
  printf '%s' "${out}" | jq -e '.credential == "prod--admin"' >/dev/null
  printf '%s' "${out}" | jq -e '.meta.site == "prod"' >/dev/null
  printf '%s' "${out}" | jq -e '.meta.backend == "plaintext"' >/dev/null
  printf '%s' "${out}" | jq -e '.meta.account == "alice@example.com"' >/dev/null
}

@test "creds-show: NEVER emits the secret value (privacy invariant; sentinel canary)" {
  _seed_cred prod--admin prod plaintext
  printf 'sekret-do-not-leak-show' > "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret"
  chmod 600 "${BROWSER_SKILL_HOME}/credentials/prod--admin.secret"
  out="$(run_show --as prod--admin)"
  if printf '%s' "${out}" | grep -q 'sekret-do-not-leak-show'; then
    fail "creds-show output contains the secret value — PRIVACY LEAK"
  fi
  if printf '%s' "${out}" | jq -e '.meta | has("secret")' >/dev/null 2>&1; then
    fail "creds-show meta has a 'secret' key — PRIVACY LEAK"
  fi
}

@test "creds-show: missing credential exits non-zero" {
  run bash "${SCRIPTS_DIR}/browser-creds-show.sh" --as never-set
  [ "${status}" -ne 0 ] || fail "expected non-zero exit on missing credential"
}

@test "creds-show: --as is required (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-creds-show.sh"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
}

@test "creds-show: assert_safe_name rejects path traversal" {
  run bash "${SCRIPTS_DIR}/browser-creds-show.sh" --as '../escape'
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
}

@test "creds-show: works for keychain-backed credential (metadata only)" {
  _seed_cred prod--keychain prod keychain
  out="$(run_show --as prod--keychain)"
  printf '%s' "${out}" | jq -e '.meta.backend == "keychain"' >/dev/null
}

# --- --reveal flow ---

_seed_with_secret() {
  # Seed metadata + write the secret (plaintext backend → file at <name>.secret).
  local name="$1" secret="$2"
  _seed_cred "${name}" prod plaintext
  printf '%s' "${secret}" > "${BROWSER_SKILL_HOME}/credentials/${name}.secret"
  chmod 600 "${BROWSER_SKILL_HOME}/credentials/${name}.secret"
}

@test "creds-show --reveal: typed-phrase match → emits secret + secret_masked" {
  _seed_with_secret prod--admin "password123"
  out="$(printf 'prod--admin\n' | bash "${SCRIPTS_DIR}/browser-creds-show.sh" --as prod--admin --reveal 2>/dev/null)"
  printf '%s' "${out}" | jq -e '.why == "reveal"' >/dev/null
  printf '%s' "${out}" | jq -e '.secret == "password123"' >/dev/null
  printf '%s' "${out}" | jq -e '.secret_masked == "p*********3"' >/dev/null
  printf '%s' "${out}" | jq -e '.meta.site == "prod"' >/dev/null
}

@test "creds-show --reveal: typed-phrase mismatch → exit non-zero, no secret leak" {
  _seed_with_secret prod--admin "password123"
  run bash -c "printf 'wrong-name\n' | bash '${SCRIPTS_DIR}/browser-creds-show.sh' --as prod--admin --reveal"
  [ "${status}" = "${EXIT_USAGE_ERROR}" ] || fail "expected EXIT_USAGE_ERROR, got ${status}"
  if printf '%s' "${output}" | grep -q 'password123'; then
    fail "secret value leaked in mismatch error path"
  fi
}

@test "creds-show --reveal: works on keychain-backed credential (via stub)" {
  _seed_cred prod--kc prod keychain
  printf 'kc-secret-value' | bash -c "
    set -euo pipefail
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/credential.sh'
    credential_set_secret prod--kc
  "
  out="$(printf 'prod--kc\n' | bash "${SCRIPTS_DIR}/browser-creds-show.sh" --as prod--kc --reveal 2>/dev/null)"
  printf '%s' "${out}" | jq -e '.secret == "kc-secret-value"' >/dev/null
  printf '%s' "${out}" | jq -e '.secret_masked == "k*************e"' >/dev/null
}

@test "creds-show without --reveal: regression guard — no 'secret' key in output" {
  _seed_with_secret prod--admin "password123"
  out="$(run_show --as prod--admin)"
  if printf '%s' "${out}" | jq -e 'has("secret")' >/dev/null 2>&1; then
    fail "non-reveal path leaked 'secret' key — PRIVACY REGRESSION"
  fi
  if printf '%s' "${out}" | jq -e 'has("secret_masked")' >/dev/null 2>&1; then
    fail "non-reveal path leaked 'secret_masked' key — should be reveal-only"
  fi
}
