# Backplane Diagnostics Client

The client sends bounded, redacted diagnostic observations to a registered source on a local Backplane Host Agent. Start the Reporter with the application's supervision tree.

```elixir
children = [
  {Backplane.DiagnosticsClient.Reporter,
   source_id: "example-local",
   application: "example",
   host_url: "http://127.0.0.1:4222",
   token_env: "BACKPLANE_EXAMPLE_DIAGNOSTICS_TOKEN",
   version: %{"repository" => "example-org/example"}}
]
```

Configure the same source identifier and application on Host Agent and Backplane. Set the token environment variable on the application and Host Agent to the same value. Choose an independent random token for each source.

```elixir
alias Backplane.DiagnosticsClient.{Context, Reporter}

Context.with_context(%{"subject" => %{"run_id" => "run-123"}}, fn ->
  Reporter.report(%{
    "event_type" => "handled_error",
    "result" => %{"outcome" => "failure", "error_class" => "upstream_failure"},
    "evidence" => %{"exception" => %{"code" => "provider_timeout"}}
  })
end)
```

`:enqueued` means the Reporter has reserved memory for the observation. The Reporter confirms and releases the item asynchronously after the Host Agent's durable receipt. `Reporter.health/0` reports pending events, pending bytes, rejection and loss counts, and the last local confirmation. Applications should continue their own error handling when the Reporter is unavailable or at capacity. Pass identifiers, bounded structured evidence and known-safe summaries. Leave prompts, credentials, tool bodies and application state at the source.
