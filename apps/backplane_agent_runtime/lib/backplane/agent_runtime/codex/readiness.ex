defmodule Backplane.AgentRuntime.Codex.Readiness do
  @moduledoc """
  Host-provided readiness and authorization gate with cancellable waits.
  """

  alias Backplane.AgentRuntime.Error

  @error_classes ~w(validation forbidden approval_required not_found timeout cancelled transient_transport resource_conflict execution_failure malformed_result budget_exceeded unsupported_capability unknown_outcome overloaded)
  @max_environment_id_bytes 1_024
  @max_reason_bytes 256

  @spec ready?(map()) :: boolean()
  def ready?(state), do: Map.get(state, :ready, false) and Map.get(state, :authorized, false)

  @spec execute_if_ready(map(), (-> term())) :: {:ok, term()} | {:error, Error.t()}
  def execute_if_ready(state, fun) when is_map(state) and is_function(fun, 0) do
    if ready?(state),
      do: {:ok, fun.()},
      else: {:error, Error.new(:forbidden, "environment is not ready or authorized")}
  end

  @spec await((-> map()), non_neg_integer(), (-> boolean())) :: {:ok, map()} | {:error, Error.t()}
  def await(provider, timeout_ms, cancelled \\ fn -> false end)
      when is_function(provider, 0) and is_integer(timeout_ms) and timeout_ms >= 0 and
             is_function(cancelled, 0) do
    await(provider, timeout_ms, cancelled, [])
  end

  @doc """
  Waits with an optional exact `:expected_environment_id` supplied by the host.

  Missing callback IDs bind logically to that expectation; successful observations
  are returned unchanged. Explicit terminal states require a valid environment ID.
  """
  @spec await((-> map()), non_neg_integer(), (-> boolean()), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def await(provider, timeout_ms, cancelled, options)
      when is_function(provider, 0) and is_integer(timeout_ms) and timeout_ms >= 0 and
             is_function(cancelled, 0) do
    with {:ok, expected} <- expected_environment(options) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_await(provider, cancelled, deadline, expected)
    end
  end

  defp expected_environment([]), do: {:ok, nil}

  defp expected_environment(expected_environment_id: id) do
    if valid_environment_id?(id),
      do: {:ok, id},
      else: {:error, Error.new(:validation, "invalid expected environment ID")}
  end

  defp expected_environment(_),
    do: {:error, Error.new(:validation, "invalid readiness options")}

  defp do_await(provider, cancelled, deadline, expected) do
    if cancelled.() do
      {:error, Error.new(:cancelled, "readiness wait cancelled")}
    else
      case observation(provider.(), expected) do
        :waiting ->
          if System.monotonic_time(:millisecond) >= deadline do
            {:error, Error.new(:timeout, "environment readiness timed out")}
          else
            Process.sleep(min(10, max(deadline - System.monotonic_time(:millisecond), 1)))
            do_await(provider, cancelled, deadline, expected)
          end

        result ->
          result
      end
    end
  end

  defp observation(state, expected) when is_map(state) do
    with :ok <- valid_shape(state, expected),
         {:ok, id} <- environment_identity(state, expected) do
      case Map.get(state, :status) do
        status when status in [:failed, "failed"] ->
          failed(state, id, expected)

        status when status in [:unavailable, "unavailable"] ->
          unavailable(id, "unavailable", expected)

        status when status in [:closed, "closed"] ->
          unavailable(id, "closed", expected)

        _ ->
          if ready?(state), do: {:ok, state}, else: :waiting
      end
    end
  end

  defp observation(_, expected), do: malformed("invalid_environment_state", expected)

  defp valid_shape(state, expected) do
    status = Map.get(state, :status)

    cond do
      not (is_atom(status) or is_binary(status)) ->
        malformed("invalid_environment_status", expected)

      not Enum.all?([:ready, :authorized], &is_boolean(Map.get(state, &1, false))) ->
        malformed("invalid_environment_readiness", expected)

      true ->
        :ok
    end
  end

  defp environment_identity(state, expected) do
    case Map.fetch(state, :environment_id) do
      :error ->
        {:ok, expected}

      {:ok, id} ->
        cond do
          not valid_environment_id?(id) ->
            malformed("invalid_environment_id", expected)

          expected != nil and id != expected ->
            malformed("environment_identity_mismatch", expected)

          true ->
            {:ok, id}
        end
    end
  end

  defp valid_environment_id?(id) when is_binary(id),
    do: byte_size(id) in 1..@max_environment_id_bytes and String.valid?(id)

  defp valid_environment_id?(_), do: false

  defp failed(_state, nil, expected), do: malformed("environment_id_required", expected)

  defp failed(state, id, expected) do
    with {:ok, class, message} <- startup_error(Map.get(state, :error), expected) do
      {reason, truncated?} = startup_reason(message)

      {:error,
       Error.new(:execution_failure, "Environment `#{id}` failed to start: #{reason}",
         details: %{
           "environment_id" => id,
           "status" => "failed",
           "startup_class" => class,
           "reason_truncated" => truncated?
         }
       )}
    end
  end

  defp unavailable(nil, _, expected), do: malformed("environment_id_required", expected)

  defp unavailable(id, status, _expected) do
    message =
      if status == "closed",
        do: "Environment `#{id}` is closed",
        else: "environment `#{id}` is neither ready nor starting"

    {:error,
     Error.new(:not_found, message, details: %{"environment_id" => id, "status" => status})}
  end

  defp startup_error(error, expected) when is_map(error) do
    with {:ok, class} <- error_field(error, :class, &startup_class/1, expected),
         {:ok, message} <- error_field(error, :message, & &1, expected) do
      {:ok, startup_class(class), message}
    end
  end

  defp startup_error(_, _expected), do: {:ok, "unknown", nil}

  defp error_field(error, key, normalize, expected) do
    case {Map.fetch(error, key), Map.fetch(error, Atom.to_string(key))} do
      {:error, :error} ->
        {:ok, nil}

      {{:ok, value}, :error} ->
        {:ok, normalize.(value)}

      {:error, {:ok, value}} ->
        {:ok, normalize.(value)}

      {{:ok, left}, {:ok, right}} ->
        if normalize.(left) === normalize.(right),
          do: {:ok, normalize.(left)},
          else: malformed("conflicting_startup_error_aliases", expected)
    end
  end

  defp startup_class(value) when is_atom(value), do: startup_class(Atom.to_string(value))
  defp startup_class(value) when value in @error_classes, do: value
  defp startup_class(_), do: "unknown"

  defp startup_reason(message) when is_binary(message) do
    cond do
      not String.valid?(message) -> {"[invalid UTF-8 startup reason]", false}
      String.trim(message) == "" -> {"startup reason unavailable", false}
      byte_size(message) > @max_reason_bytes -> {utf8_prefix(message, @max_reason_bytes), true}
      true -> {message, false}
    end
  end

  defp startup_reason(_), do: {"startup reason unavailable", false}

  defp utf8_prefix(message, size) do
    prefix = binary_part(message, 0, size)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(message, size - 1)
  end

  defp malformed(reason, expected) do
    details =
      if expected,
        do: %{"environment_id" => expected, "reason" => reason},
        else: %{"reason" => reason}

    {:error,
     Error.new(:malformed_result, "Invalid environment readiness state", details: details)}
  end
end
