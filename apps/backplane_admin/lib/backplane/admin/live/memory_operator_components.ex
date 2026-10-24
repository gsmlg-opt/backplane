defmodule Backplane.Admin.MemoryOperatorComponents do
  use Backplane.Admin, :html

  @partition_keys ~w(memory_space_id host client scope namespace)

  attr(:record, :map, required: true)
  attr(:detail, :boolean, default: false)
  attr(:host_names, :map, default: %{})

  def source_identity(assigns) do
    metadata =
      Map.get(assigns.record, :metadata) || Map.get(assigns.record, :source_records) || %{}

    repositories =
      Map.get(assigns.record, :repository_sources) || metadata["repository_sources"] || []

    host_id = source_value(Map.get(assigns.record, :host_id), nil)
    host_name = source_value(Map.get(assigns.host_names, host_id), nil)

    assigns =
      assign(assigns,
        host_id: host_id,
        host_name: host_name,
        agent_id: source_value(Map.get(assigns.record, :agent_id), "Unknown agent"),
        repositories: repositories,
        project: Map.get(assigns.record, :project) || metadata["project"]
      )

    ~H"""
    <span class="block break-all text-xs">Host: {@host_name || @host_id || "Unknown host"}</span>
    <span :if={@detail and @host_name} class="block break-all text-xs text-on-surface-variant">Host ID: {@host_id}</span>
    <span class="block break-all text-xs">Agent: {@agent_id}</span>
    <span :if={!@detail} :for={source <- @repositories} class="block break-all text-xs text-on-surface-variant">{source["repository_id"] || source["checkout_root"] || source["cwd"] || "Unknown repository"}</span>
    <div :if={@detail} class="mt-2 space-y-2 text-sm">
      <p :if={@repositories == []} class="text-on-surface-variant">Repository unresolved: no stored source association.</p>
      <dl :for={source <- @repositories} class="memory-repository-source grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3 gap-y-1">
        <dt class="text-on-surface-variant">Repository</dt>
        <dd class="break-all">{source["repository_id"] || "Unresolved"}</dd>
        <dt :if={source["checkout_root"]} class="text-on-surface-variant">Checkout root</dt>
        <dd :if={source["checkout_root"]} class="break-all">{source["checkout_root"]}</dd>
        <dt :if={source["cwd"]} class="text-on-surface-variant">Working directory</dt>
        <dd :if={source["cwd"]} class="break-all">{source["cwd"]}</dd>
      </dl>
      <p :if={@project} class="break-all"><span class="text-on-surface-variant">Legacy project:</span> {@project}</p>
    </div>
    """
  end

  defp source_value(value, fallback) when is_binary(value),
    do: if(String.trim(value) == "", do: fallback, else: value)

  defp source_value(_value, fallback), do: fallback

  def browse_scope(params) do
    for {url, key} <- [
          {"memory_space_id", :memory_space_id},
          {"host", :host_id},
          {"client", :client_id},
          {"scope", :scope},
          {"namespace", :namespace},
          {"project", :project},
          {"repository", :repository}
        ],
        value = params[url],
        nonempty?(value),
        into: %{},
        do: {key, String.trim(value)}
  end

  def record_partition(record, fallback \\ %{}) do
    Map.merge(
      fallback,
      Map.take(record, [
        :memory_space_id,
        :host_id,
        :client_id,
        :source_client_id,
        :scope,
        :namespace
      ])
    )
  end

  def exact_partition(params) when is_map(params) do
    values = Map.take(params, @partition_keys)

    if Enum.all?(@partition_keys, &nonempty?(values[&1])) do
      {:ok,
       %{
         memory_space_id: String.trim(values["memory_space_id"]),
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
    for {key, url} <- [
          {:memory_space_id, "memory_space_id"},
          {:host_id, "host"},
          {:client_id, "client"},
          {:scope, "scope"},
          {:namespace, "namespace"},
          {:project, "project"},
          {:repository, "repository"}
        ],
        value = Map.get(partition, key),
        value not in [nil, ""],
        into: %{},
        do: {url, value}
  end

  def partition_query(_partition), do: %{}

  def selection_query(raw, extra_keys \\ []) do
    raw
    |> Map.take(@partition_keys ++ ["repository", "project"] ++ extra_keys)
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

  def status_variant(status) when status in ["pending", "enqueued", "running", "in_progress"],
    do: "warning"

  def status_variant(_status), do: "neutral"

  def format_datetime(nil), do: "—"
  def format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  def format_datetime(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  def format_datetime(value), do: to_string(value)

  defp nonempty?(value),
    do: is_binary(value) and byte_size(value) <= 512 and String.trim(value) != ""
end
