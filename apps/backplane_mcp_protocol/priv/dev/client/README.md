# Incomer development client

A local development harness for `Backplane.McpProtocol.Client`, using the
protocol package from `../../../` as a path dependency.

`Incomer.Application` starts a Streamable HTTP client against
`http://localhost:4000` with protocol version `2025-03-26`. Start a compatible
development server at that address, then run from this directory:

```sh
mix deps.get
iex -S mix
```

The client is registered as `Incomer.Client`. This harness is not a published
package or a conformance test suite.
