# Contract Decisions

## Frozen for W1.1

| Decision | Value |
| --- | --- |
| Production package | `:backplane_ai_protocol` / `Backplane.AiProtocol`. |
| TestKit package | `:backplane_ai_protocol_testkit`. |
| Dependency direction | TestKit may depend on Protocol; Protocol must never depend on TestKit. |
| Host dependencies | Protocol must not require Backplane, Phoenix, Ecto, a database, or a fixed global process name. |
| Startup | Protocol has no default network startup or automatic service launch. |
| Consumer topology | `examples/protocol_lab` is an independent Mix project, not an umbrella child. |

## Deferred to W1.2+

Request versus execution context, message/content/tool/state types, error/usage/capability types, pure lifecycle gate, translation preflight, wire contract, and WS backend selection are frozen. Framing details, auth, model catalog, cancellation/retry, and TestKit public API details remain open until their assigned work packages.
