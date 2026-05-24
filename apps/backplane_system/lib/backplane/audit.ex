defmodule Backplane.Audit do
  @moduledoc """
  Audit logging for tool calls and skill loads.

  Writes are async (fire-and-forget Task) to avoid blocking the tool call
  hot path. Arguments are never logged — only the SHA256 hash.
  """

  require Logger

  alias Backplane.Audit.{SkillLoadLog, ToolCallLog}
  alias Backplane.Repo

  @doc "Log a tool call asynchronously."
  @spec log_tool_call(map()) :: :ok
  def log_tool_call(attrs) when is_map(attrs) do
    if audit_enabled?() do
      Task.start(fn ->
        %ToolCallLog{}
        |> ToolCallLog.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.debug("Failed to log tool call: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  @doc "Log a skill load event asynchronously."
  @spec log_skill_load(map()) :: :ok
  def log_skill_load(attrs) when is_map(attrs) do
    if audit_enabled?() do
      Task.start(fn ->
        %SkillLoadLog{}
        |> SkillLoadLog.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.debug("Failed to log skill load: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  @doc "Synchronous insert for testing."
  @spec log_tool_call_sync(map()) :: :ok
  def log_tool_call_sync(attrs) when is_map(attrs) do
    %ToolCallLog{}
    |> ToolCallLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("Failed to log tool call: #{inspect(reason)}")
    end

    :ok
  end

  @doc "Synchronous insert for testing."
  @spec log_skill_load_sync(map()) :: :ok
  def log_skill_load_sync(attrs) when is_map(attrs) do
    %SkillLoadLog{}
    |> SkillLoadLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("Failed to log skill load: #{inspect(reason)}")
    end

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

  defp audit_enabled? do
    Application.get_env(:backplane, :audit_enabled, true)
  end
end
