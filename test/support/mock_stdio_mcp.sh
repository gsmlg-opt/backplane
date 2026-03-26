#!/bin/bash
# A minimal MCP server over stdio for testing.
# Reads JSON-RPC requests from stdin (one per line), responds on stdout.

while IFS= read -r line; do
  method=$(echo "$line" | grep -o '"method":"[^"]*"' | sed 's/"method":"//;s/"//')
  id=$(echo "$line" | grep -o '"id":[0-9]*' | sed 's/"id"://')

  case "$method" in
    initialize)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"2025-03-26\",\"serverInfo\":{\"name\":\"mock-stdio\",\"version\":\"0.1.0\"},\"capabilities\":{}}}"
      ;;
    tools/list)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo tool\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}}}}]}}"
      ;;
    tools/call)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echoed\"}]}}"
      ;;
    ping)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{}}"
      ;;
    *)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"
      ;;
  esac
done
