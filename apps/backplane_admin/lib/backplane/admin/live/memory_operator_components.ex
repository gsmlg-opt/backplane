defmodule Backplane.Admin.MemoryOperatorComponents do
  use Backplane.Admin, :html

  import Backplane.Admin.MemoryComponents

  @partition_keys ~w(host client scope namespace)

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:subtitle, :string, required: true)
  attr(:path, :string, required: true)
  attr(:values, :map, default: %{})
  attr(:extra, :list, default: [])

  def partition_gate(assigns) do
    ~H"""
    <div id={@id}>
      <.memory_page_header title={@title} subtitle={@subtitle} />
      <.dm_card variant="bordered" padding="lg">
        <h2 class="text-lg font-semibold">Select an exact partition</h2>
        <p class="mt-1 text-sm text-on-surface-variant">
          Host, client, scope, and namespace are required before partitioned data is queried.
        </p>
        <.form
          id={@id <> "-form"}
          for={%{}}
          as={:partition}
          phx-submit="select_partition"
          class="mt-4 grid gap-3 sm:grid-cols-2"
        >
          <.dm_input id={@id <> "-host"} name="partition[host]" label="Host" value={@values["host"] || ""} required />
          <.dm_input id={@id <> "-client"} name="partition[client]" label="Client" value={@values["client"] || ""} required />
          <.dm_input id={@id <> "-scope"} name="partition[scope]" label="Scope" value={@values["scope"] || ""} required />
          <.dm_input id={@id <> "-namespace"} name="partition[namespace]" label="Namespace" value={@values["namespace"] || ""} required />
          <.dm_input
            :for={{key, label} <- @extra}
            id={@id <> "-" <> key}
            name={"partition[#{key}]"}
            label={label}
            value={@values[key] || ""}
            required
          />
          <div class="sm:col-span-2">
            <.dm_btn type="submit" variant="primary">Open partition</.dm_btn>
          </div>
        </.form>
      </.dm_card>
    </div>
    """
  end

  def exact_partition(params) when is_map(params) do
    values = Map.take(params, @partition_keys)

    if Enum.all?(@partition_keys, &(nonempty?(values[&1]))) do
      {:ok,
       %{
         host_id: String.trim(values["host"]),
         client_id: String.trim(values["client"]),
         scope: String.trim(values["scope"]),
         namespace: String.trim(values["namespace"])
       }}
    else
      {:error, :partition_required}
    end
  end

  def partition_query(partition) when is_map(partition) do
    %{
      "host" => partition.host_id,
      "client" => partition.client_id,
      "scope" => partition.scope,
      "namespace" => partition.namespace
    }
  end

  def selection_query(raw, extra_keys \\ []) do
    raw
    |> Map.take(@partition_keys ++ extra_keys)
    |> Map.new(fn {key, value} -> {key, String.trim(value || "")} end)
    |> Map.reject(fn {_key, value} -> value == "" end)
  end

  def page(raw, default \\ 0) do
    case Integer.parse(to_string(raw || default)) do
      {offset, ""} when offset >= 0 and offset <= 10_000 -> offset
      _ -> default
    end
  end

  def status_variant(status) when status in ["complete", "done", "active"], do: "success"
  def status_variant(status) when status in ["failed", "dead_letter", "blocked"], do: "error"
  def status_variant(status) when status in ["pending", "enqueued", "running", "in_progress"], do: "warning"
  def status_variant(_status), do: "neutral"

  def format_datetime(nil), do: "—"
  def format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  def format_datetime(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  def format_datetime(value), do: to_string(value)

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
