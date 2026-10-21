defmodule Backplane.Memory.Operations.Selection do
  @moduledoc "Bounded trusted-operator discovery of canonical host/project partitions."

  import Ecto.Query
  alias Backplane.Memory.Projections.ProjectedSession
  alias Backplane.Skills.Host
  alias Backplane.{MemorySpaces, Repo}

  @limit 50

  def list do
    hosts = Repo.all(from(h in Host, order_by: [desc: h.inserted_at, asc: h.id], limit: @limit))
    host_names = Map.new(hosts, &{&1.id, &1.name})

    registered =
      Enum.flat_map(hosts, fn host ->
        case MemorySpaces.resolve_host_partition(host.id, host.memory_scope, "private") do
          {:ok, p} ->
            [
              %{
                label: host.name,
                query:
                  query(p.memory_space_id, host.id, "host:" <> host.id, p.scope, p.namespace, nil)
              }
            ]

          _ ->
            []
        end
      end)

    sessions =
      Repo.all(
        from(s in ProjectedSession,
          order_by: [desc: s.updated_at, asc: s.subject_id],
          limit: @limit
        )
      )
      |> Enum.map(fn s ->
        %{
          label:
            Map.get(host_names, s.host_id, s.host_id) <> " · " <> (s.project || "No project"),
          query: query(s.memory_space_id, s.host_id, s.client_id, s.scope, s.namespace, s.project)
        }
      end)

    {:ok, Enum.uniq_by(sessions ++ registered, & &1.query) |> Enum.take(@limit)}
  rescue
    _ -> {:error, :partition_discovery_unavailable}
  end

  defp query(space, host, client, scope, namespace, project) do
    %{
      "memory_space_id" => space,
      "host" => host,
      "client" => client,
      "scope" => scope,
      "namespace" => namespace,
      "project" => project
    }
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
  end
end
