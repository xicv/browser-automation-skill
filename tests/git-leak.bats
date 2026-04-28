load helpers

setup() {
  TEST_REPO="$(mktemp -d "${TMPDIR:-/tmp}/git-leak.XXXXXX")"
  cd "${TEST_REPO}"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  cp "${REPO_ROOT}/.gitignore" .
}

teardown() {
  cd "${REPO_ROOT}"
  rm -rf "${TEST_REPO}"
}

@test "gitignore: ignores common credential / session / capture patterns" {
  for path in \
      .browser-skill/sessions/x.json \
      .browser-skill/credentials/x.json \
      .browser-skill/captures/001/network.har \
      sessions/x.json \
      credentials/x.json \
      captures/001/screenshot.png \
      sample.creds.json \
      private.pem \
      private.key \
      cert.crt \
      .env \
      .env.local \
      secrets.yaml \
      secrets.json
  do
    mkdir -p "$(dirname "${path}")"
    : > "${path}"
    run git check-ignore "${path}"
    assert_status 0
  done
}

@test "gitignore: does NOT ignore shareable team files" {
  for path in \
      .browser-skill/sites/prod.json \
      .browser-skill/flows/morning.flow.yaml \
      .browser-skill/baselines.json \
      .browser-skill/blocklist.txt \
      .browser-skill/config.json \
      .browser-skill/version
  do
    mkdir -p "$(dirname "${path}")"
    : > "${path}"
    run git check-ignore "${path}"
    assert_status 1   # not ignored
  done
}
