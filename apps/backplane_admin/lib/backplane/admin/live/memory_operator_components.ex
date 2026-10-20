defmodule Backplane.Admin.MemoryOperatorComponents do
  use Backplane.Admin, :html

  @partition_keys ~w(memory_space_id host client scope namespace)

  attr(:path, :string, required: true)
  attr(:selection, :map, default: %{})
  attr(:filters, :map, default: %{})

  def source_filters(assigns) do
    assigns =
      assign(
        assigns,
        :filters,
        Map.take(
          assigns.filters,
          ~w(q type session sort event_type tool minimum_importance error file from to status operation actor target query agent run stream state limit agent_id)
        )
      )

    ~H"""
    <form id="memory-source-filters" method="get" action={@path} class="mb-5 flex flex-wrap items-end gap-3">
      <input :for={{key, value} <- @filters} type="hidden" name={key} value={value} />
      <input :for={{key, value} <- Map.take(@selection, ~w(memory_space_id client scope namespace))} type="hidden" name={key} value={value} />
      <.dm_input id="memory-source-host" name="host" label="Source host (optional)" value={@selection["host"] || ""} />
      <.dm_input id="memory-source-repository" name="repository" label="Repository (optional)" value={@selection["repository"] || ""} />
      <.dm_input id="memory-source-project" name="project" label="Legacy project (optional)" value={@selection["project"] || ""} />
      <.dm_btn type="submit" native_submit variant="primary">Apply source filters</.dm_btn>
      <.link href={@path <> "?" <> URI.encode_query(@filters)} class="text-primary underline">All sources</.link>
    </form>
    """
  end

  attr(:record, :map, required: true)
  attr(:detail, :boolean, default: false)

  def source_identity(assigns) do
    metadata =
      Map.get(assigns.record, :metadata) || Map.get(assigns.record, :source_records) || %{}

    repositories =
      Map.get(assigns.record, :repository_sources) || metadata["repository_sources"] || []

    assigns =
      assign(assigns,
        repositories: repositories,
        project: Map.get(assigns.record, :project) || metadata["project"]
      )

    ~H"""
    <span class="block break-all text-xs">{Map.get(@record, :host_id) || "Unknown source"}</span>
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
