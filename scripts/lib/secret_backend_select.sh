# scripts/lib/secret_backend_select.sh
# Smart per-OS credentials backend auto-detection per parent spec §1.
#
# detect_backend → echoes one of: keychain | libsecret | plaintext
#
# Resolution order:
#   1. ${BROWSER_SKILL_FORCE_BACKEND} ∈ {keychain, libsecret, plaintext} →
#      echoed verbatim. (Test override; also a user knob if auto-detect picks
#      wrong on their box — e.g. Linux without a running D-Bus session.)
#   2. uname -s gates per-OS:
#      - Darwin   + ${KEYCHAIN_SECURITY_BIN:-security}     on PATH → keychain
#      - Linux    + ${LIBSECRET_TOOL_BIN:-secret-tool}     on PATH → libsecret
#      - Anything else                                              → plaintext
#   3. We do NOT probe D-Bus reachability for libsecret. That probe is brittle
#      (no clean way to tell "no agent" from "no item matching"), and the user
#      can override via BROWSER_SKILL_FORCE_BACKEND=plaintext when needed.
#
# Source from any verb that needs to choose a backend (creds-add, future
# creds-migrate, etc). Requires lib/common.sh sourced first (assert_safe_name,
# EXIT_*).

[ -n "${BROWSER_SKILL_SECRET_BACKEND_SELECT_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SECRET_BACKEND_SELECT_LOADED=1

readonly _BACKEND_VALID_SET="keychain libsecret plaintext"

detect_backend() {
  if [ -n "${BROWSER_SKILL_FORCE_BACKEND:-}" ]; then
    case " ${_BACKEND_VALID_SET} " in
      *" ${BROWSER_SKILL_FORCE_BACKEND} "*)
        printf '%s\n' "${BROWSER_SKILL_FORCE_BACKEND}"
        return 0
        ;;
      *)
        # Invalid override — fall through to auto-detect (don't fail; the
        # user typo'd a backend name but we still want a working default).
        ;;
    esac
  fi

  case "$(uname -s)" in
    Darwin)
      if command -v "${KEYCHAIN_SECURITY_BIN:-security}" >/dev/null 2>&1; then
        printf 'keychain\n'
        return 0
      fi
      ;;
    Linux)
      if command -v "${LIBSECRET_TOOL_BIN:-secret-tool}" >/dev/null 2>&1; then
        printf 'libsecret\n'
        return 0
      fi
      ;;
  esac

  printf 'plaintext\n'
}
