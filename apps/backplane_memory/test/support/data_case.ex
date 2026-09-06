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
    partition =
      canonical_partition(host_id,
        client_id: Keyword.get(opts, :client_id, "host:#{host_id}"),
        source_client_id: Keyword.get(opts, :source_client_id),
        scope: Keyword.get(opts, :scope, "global"),
        namespace: Keyword.get(opts, :namespace, "private")
      )

    opts
    |> Keyword.merge(Map.to_list(partition))
    |> Keyword.put(:host_id, host_id)
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
