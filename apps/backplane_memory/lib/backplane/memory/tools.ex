defmodule Backplane.Memory.Tools do
  @moduledoc "Managed MCP service exposing the five `memory::*` tools over the global record store."

  alias Backplane.Memory.{Record, Records}
  alias Backplane.MemoryToolContract

  def prefix, do: "memory"

  def enabled?, do: Backplane.Settings.get("services.memory.enabled") == true

  def tools do
    schemas = MemoryToolContract.schemas()
    descriptions = MemoryToolContract.descriptions()

    for short <- ~w(search get recent remember forget) do
      name = prefix() <> "::" <> short
      description = Map.fetch!(descriptions, name)

      %{
        name: name,
        description: description,
        input_schema: Map.fetch!(schemas, name),
        handler: handler(short)
      }
    end
  end

  defp handler("search"), do: &search/2
  defp handler("get"), do: &get/2
  defp handler("recent"), do: &recent/2
  defp handler("remember"), do: &remember/2
  defp handler("forget"), do: &forget/2

  def search(%{"query" => query} = args, _auth) when is_binary(query) and query != "" do
    filters = filters(args, ~w(kind subject since until include_inactive limit token_budget))

    guarded(fn -> %{"results" => query |> Records.search(filters) |> Enum.map(&render/1)} end)
  end

  def search(_args, _auth), do: {:error, "invalid: query is required"}

  def recent(args, _auth) do
    filters = filters(args, ~w(since limit))
    guarded(fn -> %{"results" => filters |> Records.recent() |> Enum.map(&render/1)} end)
  end

  def get(%{"id" => id}, _auth) when is_binary(id) do
    case Records.get(id) do
      {:ok, %{record: record, history: history}} ->
        {:ok, %{"record" => render(record), "history" => Enum.map(history, &render/1)}}

      {:error, :not_found} ->
        {:error, "not_found"}
    end
  end

  def get(_args, _auth), do: {:error, "invalid: id is required"}

  def remember(%{"content" => content} = args, auth) when is_binary(content) do
    metadata = Map.get(auth, :principal_metadata) || %{}

    with {:ok, observed_at} <- observed_at(args["observed_at"]) do
      attrs =
        args
        |> Map.take(~w(content kind title subjects property tags session_id integration request_key))
        |> Map.put("writer", writer(args["writer"]))
        |> Map.put("client_id", Map.get(auth, :client_id))
        |> Map.put("host_id", metadata["host_id"] || args["host"])
        |> Map.put("agent_id", args["agent"])
        |> Map.put("observed_at", observed_at)
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      case Records.remember(attrs) do
        {:ok, record} -> {:ok, render(record)}
        {:error, changeset} -> {:error, "invalid: " <> changeset_errors(changeset)}
      end
    end
  end

  def remember(_args, _auth), do: {:error, "invalid: content is required"}

  def forget(%{"id" => id, "reason" => reason}, _auth)
      when is_binary(id) and is_binary(reason) and reason != "" do
    case Records.forget(id, reason) do
      {:ok, record} -> {:ok, render(record)}
      {:error, :not_found} -> {:error, "not_found"}
    end
  end

  def forget(%{"id" => _}, _auth), do: {:error, "invalid: reason is required"}
  def forget(_args, _auth), do: {:error, "invalid: id and reason are required"}

  # Optional caller-supplied observation time (e.g. an offline host write
  # uploaded later); defaults to now in `Records.remember/1`.
  defp observed_at(nil), do: {:ok, nil}

  defp observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} -> {:error, "invalid: observed_at"}
    end
  end

  defp observed_at(_value), do: {:error, "invalid: observed_at"}

  defp writer("user"), do: "user"
  defp writer(_), do: "agent"

  defp filters(args, keys) do
    args
    |> Map.take(keys)
    |> put_alias(args, "host", "host_id")
    |> put_alias(args, "agent", "agent_id")
  end

  defp put_alias(filters, args, from, to) do
    case args[from] do
      nil -> filters
      value -> Map.put(filters, to, value)
    end
  end

  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    error in ArgumentError -> {:error, "invalid: " <> Exception.message(error)}
  end

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", inspect(v)) end)
    end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field} #{&1}") end)
    |> Enum.join("; ")
  end

  defp render(%Record{} = r), do: Records.to_map(r)
end
