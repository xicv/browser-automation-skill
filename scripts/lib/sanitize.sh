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
