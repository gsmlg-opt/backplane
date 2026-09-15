defmodule Backplane.Memory.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Backplane.Memory.DataCase
    end
  end

  setup tags do
    BackplaneDataCase.setup_sandbox(repo(), tags)
    :ok
  end

  @doc "Repo configured for backplane_memory (runtime-resolved to avoid compile-time cross-app coupling)."
  def repo, do: Application.fetch_env!(:backplane_memory, :repo)

  def canonical_partition(host_id, opts \\ []) do
    memory_space_id = Backplane.Memory.IngestFixtures.ensure_memory_space!(host_id)
    client_id = Keyword.get(opts, :client_id, "host:#{host_id}")

    %{
      memory_space_id: memory_space_id,
      host_id: host_id,
      client_id: client_id,
      source_client_id: Keyword.get(opts, :source_client_id, client_id),
      scope: Keyword.get(opts, :scope, "global"),
      namespace: Keyword.get(opts, :namespace, "private")
    }
  end

  def canonical_memory_opts(host_id, opts \\ []) do
    client_id = Keyword.get(opts, :client_id, "host:#{host_id}")

    partition =
      canonical_partition(host_id,
        client_id: client_id,
        source_client_id: Keyword.get(opts, :source_client_id, client_id),
        scope: Keyword.get(opts, :scope, "global"),
        namespace: Keyword.get(opts, :namespace, "private")
      )

    opts
    |> Keyword.merge(Map.to_list(partition))
    |> Keyword.put(:host_id, host_id)
  end

  def canonical_recall_candidate(partition, content, opts \\ []) do
    memory =
      %Backplane.Memory.Memories.Memory{}
      |> Backplane.Memory.Memories.Memory.changeset(%{
        content: content,
        memory_space_id: partition.memory_space_id,
        memory_type: Keyword.get(opts, :memory_type, "semantic"),
        agent_id: "recall-fixture",
        host_id: partition.host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace,
        metadata: %{}
      })
      |> repo().insert!()

    Backplane.Memory.Recall.Candidate.new(
      Map.merge(Map.drop(partition, [:source_client_id]), %{
        id: memory.id,
        kind: Keyword.get(opts, :kind, :memory),
        memory_type: Keyword.get(opts, :memory_type, :semantic),
        content: content,
        source_ids: [memory.id],
        source_refs: [%{type: :memory, id: memory.id}],
        token_estimate: Keyword.get(opts, :token_estimate, 1),
        inserted_at: Keyword.get(opts, :inserted_at)
      })
    )
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

defmodule Backplane.Memory.EventTestPartition do
  @moduledoc false

  @host_id "event-test-owner"

  def ensure! do
    Backplane.Memory.IngestFixtures.ensure_memory_space!(@host_id)
  end

  def attrs(attrs) when is_map(attrs) do
    Map.merge(
      %{
        memory_space_id: Backplane.Memory.IngestFixtures.memory_space_id(@host_id),
        scope: "global",
        namespace: "private"
      },
      attrs
    )
  end

  def attrs_list(attrs_list) when is_list(attrs_list), do: Enum.map(attrs_list, &attrs/1)
end
