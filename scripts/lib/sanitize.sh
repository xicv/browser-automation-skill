# scripts/lib/sanitize.sh — capture sanitization (Phase 7 part 1-ii).
#
# Two-function API:
#   sanitize_har     — redact sensitive HAR fields (request/response headers,
#                      URL params). Reads HAR JSON on stdin; emits redacted
#                      HAR JSON on stdout.
#   sanitize_console — redact sensitive console message fields (password,
#                      secret, token values inline in the message text).
#                      Reads console-array JSON on stdin; emits redacted
#                      array on stdout.
#
# Per parent spec §8.3:
# - Header sentinel:  "***REDACTED***" (whole-value replace).
# - URL/console mask: "***" (param-value or field-value replace; key preserved).
#
# Sensitive HEADER name set (case-insensitive, ascii_downcase compared):
#   request:  authorization | cookie | x-api-key | x-auth-token
#   response: set-cookie    | authorization
#
# Sensitive URL PARAM key set (key=value pairs in the query string):
#   api_key | token | access_token | client_secret
#
# Sensitive CONSOLE FIELD key set (case-insensitive in the message text):
#   password | secret | token
#
# 7-1-ii scope: pure functions, no verb integration. 7-1-iii wires this into
# `inspect --capture-console --capture-network --capture` so console.json +
# network.har are sanitized before disk-persist.
#
# jq compatibility: avoids named-capture groups (`(?<name>...)`) since older
# jq builds reject them. Per-key sub() loop is portable across jq 1.6+.

[ -n "${_BROWSER_LIB_SANITIZE_LOADED:-}" ] && return 0
readonly _BROWSER_LIB_SANITIZE_LOADED=1

# sanitize_har — read HAR JSON from stdin, write redacted HAR to stdout.
sanitize_har() {
  jq '
    def _redact_header_request:
      if (.name | ascii_downcase) as $n
         | $n == "authorization" or $n == "cookie"
           or $n == "x-api-key" or $n == "x-auth-token"
      then .value = "***REDACTED***" else . end;

    def _redact_header_response:
      if (.name | ascii_downcase) as $n
         | $n == "authorization" or $n == "set-cookie"
      then .value = "***REDACTED***" else . end;

    def _mask_url_params:
      reduce ("api_key", "token", "access_token", "client_secret") as $k
        (.; sub("(?<pre>[?&])" + $k + "=[^&]*"; "\(.pre)" + $k + "=***"));

    .log.entries |= map(
      .request.headers  |= map(_redact_header_request)
      | .response.headers |= map(_redact_header_response)
      | .request.url    |= _mask_url_params
    )
  '
}

# sanitize_console — read console-array JSON from stdin, write redacted array.
# Each entry is {level, text, ...}; text gets per-key field masking.
sanitize_console() {
  jq '
    def _mask_console_text:
      reduce ("password", "secret", "token") as $k
        (.; gsub("(?i)(?<pre>\\b" + $k + "\\b\\s*[:=]\\s*)\\S+"; "\(.pre)***"));

    map(
      if has("text") and (.text | type) == "string"
      then .text |= _mask_console_text
      else . end
    )
  '
}

# sanitize_inspect_reply (Phase 7 part 1-iii) — applied to the bridge's
# combined inspect reply. Sanitizes both .console_messages (via the same
# rules as sanitize_console) and .network_requests (each request entry is
# wrapped in a HAR envelope and run through sanitize_har in-memory).
# Reads inspect-shaped JSON on stdin, emits same shape with sensitive values
# redacted in place. Non-sensitive fields (verb, tool, why, status, matches,
# screenshot_path, etc.) pass through untouched. Used by browser-inspect.sh
# --capture for both stdout-side (agent-visibility) and disk-side (per-aspect
# files: console.json + network.har) sanitization — single transformation,
# both sinks.
sanitize_inspect_reply() {
  local raw out
  raw="$(cat)"
  out="${raw}"

  if printf '%s' "${raw}" | jq -e 'has("console_messages") and (.console_messages | type == "array")' >/dev/null 2>&1; then
    local sc
    sc="$(printf '%s' "${raw}" | jq '.console_messages' | sanitize_console)"
    out="$(printf '%s' "${out}" | jq --argjson sc "${sc}" '.console_messages = $sc')"
  fi

  if printf '%s' "${raw}" | jq -e 'has("network_requests") and (.network_requests | type == "array")' >/dev/null 2>&1; then
    local sr_envelope sr
    sr_envelope="$(printf '%s' "${raw}" | jq '{log: {entries: .network_requests}}' | sanitize_har)"
    sr="$(printf '%s' "${sr_envelope}" | jq '.log.entries')"
    out="$(printf '%s' "${out}" | jq --argjson sr "${sr}" '.network_requests = $sr')"
  fi

  printf '%s' "${out}"
}
