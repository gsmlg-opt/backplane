# Replace Backplane MCP Protocol With Backplane.McpProtocol Source

**Goal:** Replace the old `apps/backplane_mcp_protocol` implementation with the Backplane.McpProtocol MCP implementation, keeping the umbrella app directory and OTP app name as `backplane_mcp_protocol`.

**Decision:** The replacement source must live at `apps/backplane_mcp_protocol/`. Mix requires umbrella child directory names to match OTP app names, so the local app is `:backplane_mcp_protocol`. The Elixir modules are renamed to `Backplane.McpProtocol.*`.

## Plan

- [x] Move the replacement source into `apps/backplane_mcp_protocol/`.
- [x] Keep the local Mix app as `:backplane_mcp_protocol`.
- [x] Update `apps/backplane_mcp` to depend on `{:backplane_mcp_protocol, in_umbrella: true}`.
- [x] Replace Backplane runtime references with `Backplane.McpProtocol` modules and Backplane-local compatibility helpers where needed.
- [x] Update runtime config, telemetry, startup, and test references to the `Backplane.McpProtocol` namespace.
- [x] Verify there is no temporary replacement app directory and no Hex protocol lock entry.
- [x] Run scoped compile and tests.

## Verification

```bash
mix deps.get
mix compile --warnings-as-errors
mix test apps/backplane_mcp/test/backplane/mcp/info_test.exs \
  apps/backplane_mcp/test/backplane/transport/router_test.exs \
  apps/backplane_mcp/test/backplane/transport/mcp_handler_test.exs \
  apps/backplane_mcp/test/backplane/transport/sse_test.exs \
  apps/backplane_mcp/test/backplane/proxy/sse_parser_test.exs \
  apps/backplane_mcp/test/backplane/proxy/upstream_test.exs
mix test apps/backplane_mcp_protocol/test/backplane/mcp_protocol/protocol_test.exs \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/mcp/id_test.exs \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/mcp/message_test.exs \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/mcp/error_test.exs \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/mcp/response_test.exs \
  apps/backplane_mcp_protocol/test/backplane/mcp_protocol/sse/parser_test.exs
```
