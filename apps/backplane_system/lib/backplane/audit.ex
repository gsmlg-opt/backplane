defmodule Backplane.Audit do
  @moduledoc """
  Audit logging for tool calls and skill loads.

  Writes are enqueued to `Backplane.Audit.Writer` to avoid blocking the tool
  call hot path. Arguments are never logged — only the SHA256 hash.
  """

  require Logger

  import Ecto.Query

  alias Backplane.Audit.{SkillLoadLog, ToolCallLog, Writer}
  alias Backplane.Repo

  @doc "Log a tool call asynchronously via the supervised audit writer."
  @spec log_tool_call(map()) :: :ok
  def log_tool_call(attrs) when is_map(attrs) do
    if audit_enabled?() do
      attrs
      |> ensure_event_id()
      |> Map.put(:type, :tool_call)
      |> Writer.enqueue()
      |> dropped_log(:tool_call)
    end

    :ok
  end

  @doc "Log a skill load event asynchronously via the supervised audit writer."
  @spec log_skill_load(map()) :: :ok
  def log_skill_load(attrs) when is_map(attrs) do
    if audit_enabled?() do
      attrs
      |> ensure_event_id()
      |> Map.put(:type, :skill_load)
      |> Writer.enqueue()
      |> dropped_log(:skill_load)
    end

    :ok
  end

  @doc "Synchronous insert for testing."
  @spec persist_tool_call!(map()) :: ToolCallLog.t()
  def persist_tool_call!(attrs) when is_map(attrs) do
    attrs = ensure_event_id(attrs)

    %ToolCallLog{}
    |> ToolCallLog.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Synchronous insert for testing."
  @spec persist_skill_load!(map()) :: SkillLoadLog.t()
  def persist_skill_load!(attrs) when is_map(attrs) do
    attrs = ensure_event_id(attrs)

    %SkillLoadLog{}
    |> SkillLoadLog.changeset(attrs)
    |> Repo.insert!()
  end

  @doc false
  @spec log_tool_call_sync(map()) :: :ok
  def log_tool_call_sync(attrs) when is_map(attrs) do
    _ = persist_tool_call!(attrs)
    :ok
  end

  @doc false
  @spec log_skill_load_sync(map()) :: :ok
  def log_skill_load_sync(attrs) when is_map(attrs) do
    _ = persist_skill_load!(attrs)
    :ok
  end

  @doc "Hash arguments for the audit log (never store raw arguments)."
  @spec hash_arguments(map()) :: String.t()
  def hash_arguments(args) when is_map(args) do
    args
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def hash_arguments(_), do: nil

  @doc "Generates a unique audit event identifier."
  @spec generate_event_id() :: String.t()
  def generate_event_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  @doc "Lists persisted tool-call audit rows with optional filters."
  @spec list_tool_call_logs(map(), keyword()) :: [ToolCallLog.t()]
  def list_tool_call_logs(filters \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(t in ToolCallLog)
    |> maybe_filter_audit_since(filters[:since])
    |> maybe_filter_audit_until(filters[:until])
    |> maybe_filter_audit_tool_name(filters[:tool_name])
    |> maybe_filter_audit_status(filters[:status])
    |> maybe_filter_audit_client(filters[:client_id])
    |> order_by([t], desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Lists persisted skill-load audit rows with optional filters."
  @spec list_skill_load_logs(map(), keyword()) :: [SkillLoadLog.t()]
  def list_skill_load_logs(filters \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(s in SkillLoadLog)
    |> maybe_filter_audit_since(filters[:since])
    |> maybe_filter_audit_until(filters[:until])
    |> maybe_filter_audit_skill_name(filters[:skill_name])
    |> maybe_filter_audit_client(filters[:client_id])
    |> order_by([s], desc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_audit_since(query, nil), do: query
  defp maybe_filter_audit_since(query, since), do: where(query, [r], r.inserted_at >= ^since)

  defp maybe_filter_audit_until(query, nil), do: query
  defp maybe_filter_audit_until(query, until), do: where(query, [r], r.inserted_at <= ^until)

  defp maybe_filter_audit_tool_name(query, nil), do: query
  defp maybe_filter_audit_tool_name(query, name), do: where(query, [t], t.tool_name == ^name)

  defp maybe_filter_audit_skill_name(query, nil), do: query
  defp maybe_filter_audit_skill_name(query, name), do: where(query, [s], s.skill_name == ^name)

  defp maybe_filter_audit_status(query, nil), do: query
  defp maybe_filter_audit_status(query, status), do: where(query, [t], t.status == ^status)

  defp maybe_filter_audit_client(query, nil), do: query
  defp maybe_filter_audit_client(query, client_id), do: where(query, [r], r.client_id == ^client_id)

  defp ensure_event_id(%{event_id: event_id} = attrs) when is_binary(event_id) and event_id != "" do
    attrs
  end

  defp ensure_event_id(attrs), do: Map.put(attrs, :event_id, generate_event_id())

  defp audit_enabled? do
    if settings_available?() do
      apply(Backplane.Observability.Settings, :audit_enabled?, [])
    else
      Application.get_env(:backplane, :audit_enabled, true)
    end
  end

  defp settings_available? do
    Code.ensure_loaded?(Backplane.Observability.Settings) and
      Process.whereis(Backplane.Observability.Settings) != nil
  end

  defp dropped_log(:ok, _kind), do: :ok

  defp dropped_log({:error, reason}, kind) do
    Logger.debug("Failed to enqueue #{kind} audit event: #{inspect(reason)}")
    :ok
  end
end
