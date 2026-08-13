defmodule Backplane.Memory.Operations.Activity do
  @moduledoc false

  import Ecto.Query

  alias Backplane.Memory.Activity
  alias Backplane.Memory.Projections.ActivityDaily

  @tenant_keys ~w(client_id scope namespace)a

  # This module is the trusted-operator boundary used by the private admin endpoint.
  # Public Memory APIs remain exact-host and never accept a cross-host authorization flag.
  def partitions(opts \\ [])

  def partitions(opts) when is_list(opts) do
    with {:ok, options} <- partition_options(opts) do
      rows =
        ActivityDaily
        |> where(
          [row],
          row.host_id != "" and row.client_id != "" and row.scope != "" and row.namespace != ""
        )
        |> maybe_filter(:client_id, options.client_id)
        |> maybe_filter(:scope, options.scope)
        |> maybe_filter(:namespace, options.namespace)
        |> distinct(true)
        |> order_by([row],
          asc: row.client_id,
          asc: row.scope,
          asc: row.namespace,
          asc: row.host_id
        )
        |> limit(^options.limit)
        |> select([row], %{
          host_id: row.host_id,
          client_id: row.client_id,
          scope: row.scope,
          namespace: row.namespace
        })
        |> repo().all()

      {:ok, rows}
    end
  end

  def partitions(_opts), do: {:error, :invalid_options}

  def host_breakdown(tenant, opts \\ [])

  def host_breakdown(tenant, opts) when is_map(tenant) and is_list(opts) do
    with {:ok, tenant} <- exact_tenant(tenant),
         {:ok, partitions} <-
           partitions(
             client_id: tenant.client_id,
             scope: tenant.scope,
             namespace: tenant.namespace,
             limit: 100
           ),
         {:ok, rows} <- exact_host_rows(partitions, opts) do
      limit = Keyword.get(opts, :limit, 20)
      {:ok, rows |> Enum.sort_by(&{-&1.event_count, &1.key}) |> Enum.take(limit)}
    end
  end

  def host_breakdown(_tenant, _opts), do: {:error, :invalid_options}

  defp exact_host_rows(partitions, opts) do
    Enum.reduce_while(partitions, {:ok, []}, fn partition, {:ok, acc} ->
      case Activity.breakdown(partition, :host_id, opts) do
        {:ok, rows} -> {:cont, {:ok, rows ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp partition_options(opts) do
    allowed = [:client_id, :scope, :namespace, :limit]

    if Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] do
      options = %{
        client_id: Keyword.get(opts, :client_id),
        scope: Keyword.get(opts, :scope),
        namespace: Keyword.get(opts, :namespace),
        limit: Keyword.get(opts, :limit, 100)
      }

      if valid_partition_options?(options),
        do: {:ok, options},
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp valid_partition_options?(options) do
    is_integer(options.limit) and options.limit in 1..100 and
      Enum.all?([options.client_id, options.scope, options.namespace], &valid_optional?/1)
  end

  defp exact_tenant(tenant) do
    values =
      Map.new(@tenant_keys, fn key ->
        {key, Map.get(tenant, key) || Map.get(tenant, Atom.to_string(key))}
      end)

    if Enum.all?(values, fn {_key, value} -> valid_required?(value) end),
      do: {:ok, values},
      else: {:error, :invalid_options}
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field_name, value),
    do: where(query, [row], field(row, ^field_name) == ^value)

  defp valid_optional?(nil), do: true
  defp valid_optional?(value), do: valid_required?(value)

  defp valid_required?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 512

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
