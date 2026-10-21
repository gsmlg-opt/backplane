Application.ensure_all_started(:mimic)

Mox.defmock(Backplane.McpProtocol.MockTransport, for: Backplane.McpProtocol.Transport.Behaviour)

if Code.ensure_loaded?(HTTP.WebSocket), do: Mimic.copy(HTTP.WebSocket)

ExUnit.start(exclude: [:integration], max_cases: System.schedulers_online() * 2)
