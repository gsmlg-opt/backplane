#!/bin/bash
# Option-driven MCP stdio fixture. Requests are recorded outside stdout so the
# protocol stream remains newline-delimited JSON only.

mode="${MCP_TEST_MODE:-legacy}"
event_file="${MCP_TEST_EVENT_FILE:-}"
violation_file="${MCP_TEST_VIOLATION_FILE:-}"

record_request() {
  if [ -n "$event_file" ]; then
    printf '%s\n' "$1" >> "$event_file"
  fi
}

record_violation() {
  if [ -n "$violation_file" ]; then
    printf '%s\n' "$1" >> "$violation_file"
  fi
}

while IFS= read -r line; do
  method=$(printf '%s' "$line" | sed -nE 's/.*"method"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
  id=$(printf '%s' "$line" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*("[^"]*"|-?[0-9]+|null).*/\1/p')
  record_request "$line"

  case "$method" in
    notifications/initialized)
      ;;

    server/discover)
      case "$mode" in
        legacy|auto_legacy)
          printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id"
          ;;
        discover_jsonrpc_error|discover_500)
          printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"Terminal discovery error"}}\n' "$id"
          ;;
        discover_malformed)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":"invalid","capabilities":{}}}\n' "$id"
          ;;
        *)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"mock-modern-stdio","version":"0.1.0"}}}}\n' "$id"
          ;;
      esac
      ;;

    initialize)
      if [ "$mode" = "modern" ] || [ "$mode" = "input_required" ]; then
        record_violation "initialize"
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"initialize forbidden"}}\n' "$id"
      else
        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"mock-stdio","version":"0.1.0"},"capabilities":{"tools":{}}}}\n' "$id"
      fi
      ;;

    tools/list)
      if [ "$mode" = "modern" ] || [ "$mode" = "input_required" ]; then
        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"echo","description":"Echo tool","inputSchema":{"type":"object","properties":{"message":{"type":"string"}}}}]}}\n' "$id"
      else
        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo tool","inputSchema":{"type":"object","properties":{"message":{"type":"string"}}}}]}}\n' "$id"
      fi
      ;;

    tools/call)
      if [ "$mode" = "input_required" ]; then
        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"input_required","inputRequests":{"sample":{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":1}}},"requestState":"opaque-input-required"}}\n' "$id"
      elif [ "$mode" = "modern" ]; then
        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"echoed"}]}}\n' "$id"
      else
        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"echoed"}]}}\n' "$id"
      fi
      ;;

    ping)
      if [ "$mode" = "modern" ] || [ "$mode" = "input_required" ]; then
        record_violation "ping"
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"ping forbidden"}}\n' "$id"
      else
        printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
      fi
      ;;

    *)
      if [ -n "$id" ]; then
        printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id"
      fi
      ;;
  esac
done
