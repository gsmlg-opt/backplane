#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verification_dir="$(mktemp -d)"
trap 'rm -rf "$verification_dir"' EXIT
mkdir "$verification_dir/package" "$verification_dir/consumer"

(
  cd "$repo_root/apps/backplane_diagnostics_client"
  mix hex.build --output "$verification_dir/client.tar"
)
tar -xOf "$verification_dir/client.tar" contents.tar.gz | tar -xz -C "$verification_dir/package"

cat > "$verification_dir/consumer/mix.exs" <<'ELIXIR'
defmodule DiagnosticsConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :diagnostics_consumer, version: "0.0.0", deps: [{:backplane_diagnostics_client, path: "../package"}]]
  end
end
ELIXIR

cat > "$verification_dir/consumer/verify.exs" <<'ELIXIR'
alias Backplane.DiagnosticsClient.{Receipt, Reporter}

false = Enum.any?(Application.started_applications(), fn {app, _, _} ->
  app in [:backplane, :backplane_system, :backplane_admin, :backplane_host_agent, :ecto_sql]
end)

parent = self()

sender = fn %{"batch_id" => id, "events" => [event]} ->
  send(parent, :event_delivered)
  {:ok, Receipt.response(:local, id, [Receipt.result(event, "stored")])}
end

{:ok, pid} = Reporter.start_link(application: "consumer", source_id: "consumer", interval_ms: 5, send_batch: sender)
:enqueued = Reporter.report(%{"event_type" => "run_started"})

receive do
  :event_delivered -> :ok
after
  1_000 -> raise "client consumer did not receive a report"
end

GenServer.stop(pid)
ELIXIR

(
  cd "$verification_dir/consumer"
  MIX_ENV=prod mix deps.get
  MIX_ENV=prod mix compile --warnings-as-errors
  MIX_ENV=prod mix run verify.exs
)
