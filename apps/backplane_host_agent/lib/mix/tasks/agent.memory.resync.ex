defmodule Mix.Tasks.Agent.Memory.Resync do
  @shortdoc "Requeues dead-lettered host-agent memory outbox rows"

  @moduledoc """
  Requeues all dead-lettered rows, or selected rows passed as `--seq N`, to `pending`.
  """

  use Mix.Task

  alias Backplane.HostAgent.Memory.Diagnostics

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {parsed, _rest, invalid} = OptionParser.parse(args, strict: [all: :boolean, seq: :integer])

    if invalid != [] do
      Mix.raise("expected --all or one or more --seq N options")
    end

    seqs = Keyword.get_values(parsed, :seq)

    if Keyword.get(parsed, :all, false) and seqs != [] do
      Mix.raise("--all cannot be combined with --seq")
    end

    case Diagnostics.requeue_failed_outbox(
           store: memory_store!(),
           seqs: if(seqs == [], do: :all, else: seqs)
         ) do
      {:ok, %{"requeued" => requeued}} ->
        Mix.shell().info("Requeued #{requeued} dead-lettered memory outbox row(s).")

      {:error, reason} ->
        Mix.raise("failed to requeue memory outbox rows: #{inspect(reason)}")
    end
  end

  defp memory_store! do
    Application.get_env(:backplane_host_agent, :memory_store) ||
      Mix.raise("host-agent memory store is not configured")
  end
end
