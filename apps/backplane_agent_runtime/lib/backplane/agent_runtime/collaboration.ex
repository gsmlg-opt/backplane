defmodule Backplane.AgentRuntime.Collaboration do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Opt-in collaboration wrappers over shared runtime APIs.

  Wrappers add no alternate executor or elevated privilege. Discovery and
  recorded run status are available from host state. Operations without a real
  router, continuation, cancellation, or interaction port fail explicitly.
  """

  @supported_tool_names [:agent_discover, :run_status]

  @known_tool_names [
    :agent_discover,
    :agent_spawn,
    :agent_delegate,
    :agent_send,
    :run_status,
    :run_wait,
    :run_cancel,
    :ask_user
  ]

  @type t :: map()

  @spec register_tools(map(), keyword()) :: {:ok, map(), list()} | {:error, Error.t()}
  def register_tools(host, opts \\ []) when is_map(host) and is_list(opts) do
    selected = Keyword.get(opts, :tools, [])

    cond do
      not is_list(selected) ->
        {:error, Error.new(:validation, "collaboration tools must be a list")}

      Enum.any?(selected, &(&1 not in @known_tool_names)) ->
        {:error, Error.new(:validation, "invalid collaboration tool name")}

      Enum.any?(selected, &(&1 not in @supported_tool_names)) ->
        {:error, Error.new(:unsupported_capability, "collaboration operation is not available")}

      true ->
        {:ok, host, selected}
    end
  end

  @spec discover(t(), String.t(), String.t()) :: {:ok, list()} | {:error, Error.t()}
  def discover(host, viewer, prefix) when is_map(host) and is_binary(prefix) do
    cond do
      not namespace_prefix?(prefix) ->
        {:error, Error.new(:validation, "invalid agent namespace prefix")}

      visible?(host, viewer, prefix) ->
        agents =
          host.agents
          |> Map.keys()
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.sort()

        {:ok, agents}

      true ->
        {:ok, []}
    end
  end

  @spec delegate(t(), map()) :: {:error, Error.t()}
  def delegate(_host, _request), do: unavailable(:agent_delegate)

  @spec spawn(t(), map()) :: {:error, Error.t()}
  def spawn(_host, _request), do: unavailable(:agent_spawn)

  @spec send(t(), map()) :: {:error, Error.t()}
  def send(_host, _input), do: unavailable(:agent_send)

  @spec status(t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def status(host, run_id) when is_map(host) and is_binary(run_id) do
    case Map.get(host.runs, run_id) do
      nil ->
        {:error, Error.new(:not_found, "run not found", details: %{run_id: run_id})}

      run ->
        {:ok, run}
    end
  end

  @spec wait(t(), String.t()) :: {:error, Error.t()}
  def wait(_host, _run_id), do: unavailable(:run_wait)

  @spec cancel(t(), String.t()) :: {:error, Error.t()}
  def cancel(_host, _run_id), do: unavailable(:run_cancel)

  @spec ask_user(map(), String.t()) :: {:error, Error.t()}
  def ask_user(_input, _resolver), do: unavailable(:ask_user)

  defp visible?(_host, viewer, prefix) do
    is_binary(viewer) and viewer_namespace(viewer) == prefix
  end

  defp namespace_prefix?(prefix), do: prefix != "" and String.ends_with?(prefix, ":")

  defp viewer_namespace(viewer) do
    case String.split(viewer, ":", parts: 2) do
      [namespace, _identity] when namespace != "" -> namespace <> ":"
      _other -> nil
    end
  end

  defp unavailable(operation) do
    {:error,
     Error.new(:unsupported_capability, "collaboration operation is not available",
       details: %{operation: operation}
     )}
  end
end
