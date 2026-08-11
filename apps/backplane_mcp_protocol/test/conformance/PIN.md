# MCP 2026-07-28 conformance pin

This package is tested against `@modelcontextprotocol/conformance@0.2.0-alpha.11`,
published from git commit `c321dd32035556e6769d3724a8ee97d87c3faaac`.
The frozen `requirements/2026-07-28.yaml` manifest is anchored to the
`0.2.0-alpha.10` scenario release.

The frozen requirements contain 37 scored server scenarios, 32 scored client
scenarios, and 20 `not_scored` scenarios. Every scored scenario is required;
this harness has no expected-failure list. `not_scored` scenarios still run and
are reported, but do not decide the requirements command exit status.

Run from `apps/backplane_mcp_protocol`:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix run --no-halt test/conformance/server_runner.exs -- 4105

npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 list --requirements 2026-07-28

npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 server --url http://127.0.0.1:4105/mcp --requirements 2026-07-28

MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/backplane/deps mix compile

npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 client --command "ERL_LIBS=../../_build/test/lib elixir test/conformance/client_runner.exs --" --requirements 2026-07-28
```

The client command is a one-shot Streamable HTTP adapter. The conformance
runner appends the scenario URL as the final argument and supplies
`MCP_CONFORMANCE_SCENARIO`, `MCP_CONFORMANCE_PROTOCOL_VERSION`, and optional
JSON `MCP_CONFORMANCE_CONTEXT` environment variables. It is not an MCP stdio
server. Individual client processes have a 30-second scenario timeout.
Compile once before launching the client requirements run: the upstream runner
starts all 39 client scenarios in parallel. The direct `elixir` command uses the
compiled test code paths and avoids Mix build-lock contention inside that timeout.

The first `npx -y` invocation may spend roughly 60 seconds resolving or warming
the package cache before producing output; allow startup time before diagnosing
an empty `list` response as a hang.
