defmodule Backplane.Settings.OAuthTokenRefreshWorker do
  @moduledoc """
  Oban worker that proactively refreshes device OAuth credentials.

  A cron run without args scans for due credentials and enqueues one job per
  credential. Named jobs refresh a single credential, so failures are isolated
  and visible in Oban without blocking other credentials.
  """

  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [period: 600, keys: [:credential_name]]

  require Logger

  alias Backplane.Settings.Credentials

  @default_refresh_window_ms 10 * 60 * 1000
  @default_refresh_interval_ms 7 * 24 * 60 * 60 * 1000
  @default_auth_types ["openai_oauth"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"credential_name" => name} = args}) when is_binary(name) do
    case Credentials.refresh_oauth_token(name,
           refresh_window_ms: refresh_window_ms(args),
           refresh_interval_ms: refresh_interval_ms(args)
         ) do
      {:ok, :refreshed} ->
        Logger.info("OAuth credential refreshed: #{name}")
        :ok

      {:ok, :fresh} ->
        :ok

      {:error, :not_found} ->
        {:cancel, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    refresh_window_ms = refresh_window_ms(args)
    refresh_interval_ms = refresh_interval_ms(args)

    names =
      Credentials.oauth_credentials_due_for_refresh(
        refresh_window_ms: refresh_window_ms,
        refresh_interval_ms: refresh_interval_ms,
        auth_types: auth_types(args)
      )

    Enum.reduce_while(names, :ok, fn name, _acc ->
      %{
        credential_name: name,
        refresh_window_ms: refresh_window_ms,
        refresh_interval_ms: refresh_interval_ms
      }
      |> __MODULE__.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp refresh_window_ms(args) do
    args
    |> Map.get("refresh_window_ms", @default_refresh_window_ms)
    |> parse_non_negative_integer(@default_refresh_window_ms)
  end

  defp refresh_interval_ms(args) do
    args
    |> Map.get("refresh_interval_ms", @default_refresh_interval_ms)
    |> parse_non_negative_integer(@default_refresh_interval_ms)
  end

  defp parse_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp parse_non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> default
    end
  end

  defp parse_non_negative_integer(_value, default), do: default

  defp auth_types(args) do
    case Map.get(args, "auth_types", @default_auth_types) do
      auth_types when is_list(auth_types) -> auth_types
      auth_type when is_binary(auth_type) -> [auth_type]
      _ -> @default_auth_types
    end
  end
end
