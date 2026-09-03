defmodule Backplane.Admin.LogsComponents do
  @moduledoc false

  use Backplane.Admin, :html

  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Observability.Redaction
  alias Phoenix.LiveView.JS

  @default_range_hours 24
  @page_size 50
  @metadata_limit 512
  @error_limit 1024

  attr :current, :string, required: true

  def logs_nav(assigns) do
    ~H"""
    <nav class="mb-6 flex flex-wrap gap-2">
      <.nav_link label="Overview" path={~p"/system/logs"} current={@current} />
      <.nav_link label="LLM" path={~p"/system/logs/llm"} current={@current} />
      <.nav_link label="MCP" path={~p"/system/logs/mcp"} current={@current} />
      <.nav_link label="Audit" path={~p"/system/logs/audit"} current={@current} />
      <.nav_link label="Jobs" path={~p"/system/logs/jobs"} current={@current} />
      <.nav_link label="Sinks" path={~p"/system/logs/sinks"} current={@current} />
    </nav>
    """
  end

  attr :label, :string, required: true
  attr :path, :string, required: true
  attr :current, :string, required: true

  defp nav_link(assigns) do
    active = nav_active?(assigns.path, assigns.current)
    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@path}
      class={[
        "rounded-md px-3 py-1.5 text-sm font-medium transition-colors",
        @active && "bg-primary text-on-primary",
        !@active && "bg-surface-container-high text-on-surface hover:bg-surface-container-highest"
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr :title, :string, required: true
  attr :message, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-outline-variant px-6 py-10 text-center">
      <p class="font-medium text-on-surface">{@title}</p>
      <p :if={@message} class="mt-2 text-sm text-on-surface-variant">{@message}</p>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :message, :string, required: true

  def error_state(assigns) do
    ~H"""
    <.dm_alert variant="error" title={@title}>
      {@message}
    </.dm_alert>
    """
  end

  attr :message, :string, default: "Loading records…"

  def loading_state(assigns) do
    ~H"""
    <p class="text-sm text-on-surface-variant">{@message}</p>
    """
  end

  attr :since, :any, required: true
  attr :until, :any, required: true
  attr :action, :string, required: true
  attr :fields, :list, default: []

  def time_range_form(assigns) do
    ~H"""
    <form method="get" action={@action} class="mb-4 grid gap-3 md:grid-cols-4">
      <input
        type="text"
        name="since"
        class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
        placeholder="Since (ISO8601)"
        value={datetime_param(@since)}
      />
      <input
        type="text"
        name="until"
        class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
        placeholder="Until (ISO8601)"
        value={datetime_param(@until)}
      />
      <div :for={field <- @fields} class="contents">
        <input
          class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
          name={field.name}
          placeholder={field.placeholder}
          value={field[:value] || ""}
        />
      </div>
      <div class="flex gap-2 md:col-span-2">
        <.dm_btn type="submit" variant="primary" size="sm">Apply</.dm_btn>
      </div>
    </form>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil

  def copy_field(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <code class="truncate text-xs">{@value || "-"}</code>
      <.dm_btn
        :if={@value}
        type="button"
        size="sm"
        phx-click={JS.push("copy_text", value: %{text: @value})}
      >
        Copy
      </.dm_btn>
    </div>
    """
  end

  def metadata_summary(metadata) when metadata in [nil, %{}], do: "none"

  def metadata_summary(metadata) when is_map(metadata) do
    metadata
    |> Redaction.sanitize_attributes()
    |> Jason.encode!()
    |> then(fn json ->
      {:ok, bounded} = Filter.apply_bounded(json, @metadata_limit)
      bounded
    end)
  rescue
    _ -> "[unavailable]"
  end

  def metadata_summary(_), do: "none"

  def bounded_error(nil), do: nil

  def bounded_error(text) when is_binary(text) do
    {:ok, bounded} = Filter.apply_bounded(text, @error_limit)
    bounded
  end

  def bounded_error(text), do: to_string(text)

  def payload_status(record) do
    cond do
      record_has_bytes?(record) -> "bytes only"
      true -> "none"
    end
  end

  def page_size, do: @page_size

  def default_since do
    DateTime.utc_now()
    |> DateTime.add(-@default_range_hours * 3600, :second)
  end

  def default_until do
    DateTime.utc_now() |> DateTime.add(60, :second)
  end

  def parse_time_range(params) when is_map(params) do
    %{
      since: parse_datetime(params["since"]) || default_since(),
      until: parse_datetime(params["until"]) || default_until()
    }
  end

  def parse_llm_filters(params) do
    time = parse_time_range(params)

    %{
      since: time.since,
      until: time.until,
      model: blank_to_nil(params["model"]),
      outcome: blank_to_nil(params["outcome"]),
      trace_id: blank_to_nil(params["trace_id"]),
      request_id: blank_to_nil(params["request_id"]),
      provider_id: blank_to_nil(params["provider_id"])
    }
    |> drop_nil_values()
  end

  def parse_mcp_filters(params) do
    time = parse_time_range(params)

    %{
      since: time.since,
      until: time.until,
      rpc_method: blank_to_nil(params["rpc_method"]),
      operation: blank_to_nil(params["operation"]),
      outcome: blank_to_nil(params["outcome"]),
      trace_id: blank_to_nil(params["trace_id"]),
      request_id: blank_to_nil(params["request_id"]),
      auth_kind: blank_to_nil(params["auth_kind"]),
      tool_name: blank_to_nil(params["tool_name"]),
      upstream_name: blank_to_nil(params["upstream_name"])
    }
    |> drop_nil_values()
  end

  def parse_audit_filters(params) do
    time = parse_time_range(params)

    %{
      since: time.since,
      until: time.until,
      tool_name: blank_to_nil(params["tool_name"]),
      skill_name: blank_to_nil(params["skill_name"]),
      status: blank_to_nil(params["status"]),
      client_id: blank_to_nil(params["client_id"])
    }
    |> drop_nil_values()
  end

  def parse_cursor(nil), do: nil
  def parse_cursor(""), do: nil

  def parse_cursor(cursor) when is_binary(cursor) do
    case String.split(cursor, "|", parts: 2) do
      [iso, id] ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> {dt, id}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def encode_cursor(%{inserted_at: inserted_at, id: id}) do
    "#{DateTime.to_iso8601(inserted_at)}|#{id}"
  end

  def filter_query_params(filters, extra \\ %{}) do
    filters
    |> Map.merge(extra)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new(fn
      {:since, %DateTime{} = dt} -> {"since", DateTime.to_iso8601(dt)}
      {:until, %DateTime{} = dt} -> {"until", DateTime.to_iso8601(dt)}
      {key, value} -> {to_string(key), to_string(value)}
    end)
  end

  def outcome_badge_variant("success"), do: "success"
  def outcome_badge_variant("ok"), do: "success"
  def outcome_badge_variant("error"), do: "error"
  def outcome_badge_variant("failure"), do: "error"
  def outcome_badge_variant(_), do: "neutral"

  defp nav_active?(path, current) do
    path == current or String.starts_with?(current, path <> "/")
  end

  defp record_has_bytes?(%{request_bytes: rb, response_bytes: rsp})
       when is_integer(rb) or is_integer(rsp) do
    (is_integer(rb) and rb > 0) or (is_integer(rsp) and rsp > 0)
  end

  defp record_has_bytes?(_), do: false

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: String.trim(value)
  defp blank_to_nil(value), do: value

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp datetime_param(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_param(_), do: ""
end
