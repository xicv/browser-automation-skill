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

@test "pre-commit: blocks staged plaintext password JSON" {
  cp -r "${REPO_ROOT}/.githooks" .githooks
  git config core.hooksPath .githooks
  printf '%s\n' '{"password":"hunter2"}' > leak.json
  git add -f leak.json
  run git commit -m "should fail" --no-gpg-sign
  assert_status 1
  assert_output_contains "rejected"
}

@test "pre-commit: blocks staged .pem file" {
  cp -r "${REPO_ROOT}/.githooks" .githooks
  git config core.hooksPath .githooks
  printf -- '-----BEGIN PRIVATE KEY-----\nfake\n' > my.pem
  git add -f my.pem
  run git commit -m "should fail" --no-gpg-sign
  assert_status 1
}

@test "pre-commit: allows clean commits" {
  cp -r "${REPO_ROOT}/.githooks" .githooks
  git config core.hooksPath .githooks
  echo "hello world" > README.md
  git add README.md
  run git commit -m "ok" --no-gpg-sign
  assert_status 0
}
