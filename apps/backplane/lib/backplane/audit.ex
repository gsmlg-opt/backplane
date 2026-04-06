defmodule Backplane.Audit do
  @moduledoc """
  Audit logging for tool calls and skill loads.

  Writes are async via Oban to avoid blocking the tool call hot path.
  Arguments are never logged — only the SHA256 hash for deduplication analysis.
  """

  require Logger

  alias Backplane.Audit.{SkillLoadLog, ToolCallLog}
  alias Backplane.Repo

  @doc "Log a tool call. Called from telemetry handler."
  @spec log_tool_call(map()) :: :ok
  def log_tool_call(attrs) when is_map(attrs) do
    unless audit_enabled?() do
      :ok
    else
      %ToolCallLog{}
      |> ToolCallLog.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.debug("Failed to log tool call: #{inspect(reason)}")
      end

      :ok
    end
  end

  @doc "Log a skill load event."
  @spec log_skill_load(map()) :: :ok
  def log_skill_load(attrs) when is_map(attrs) do
    unless audit_enabled?() do
      :ok
    else
      %SkillLoadLog{}
      |> SkillLoadLog.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.debug("Failed to log skill load: #{inspect(reason)}")
      end

      :ok
    end
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
