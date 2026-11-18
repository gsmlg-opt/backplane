defmodule Backplane.AgentRuntime.Codex.HistoryNotes do
  @moduledoc """
  Explicit host-selected transport for Codex encrypted History/Notes.

  Configure `ExtensionRuntime` with `history_notes: %{mode: :remote_encrypted,
  adapter: MyTransport, context: host_context, request_context: %{session_id: id,
  current_agent_name: name}, output_policy: policy}`. The host verifies backend
  capability and supplies authentication through its adapter context.

  `execute/3` receives the admitted operation, owner scope and adapter context.
  Its `:history_notes_request` contains trusted `:path`, `:body` and `:headers`.
  The body retains opaque argument strings and adds trusted context. The backend
  applies the output policy before encryption. Return `{:ok, %{"encrypted_output"
  => ciphertext, "images" => optional_images}}` or an existing runtime `Error`.
  Ordinary JSON results without `encrypted_output` use one text content block,
  followed by their independent images, matching the pinned Codex fallback.
  Output uses portable canonical content maps and rejects oversized results whole.

  `cancel/3` receives the same invocation plus its stop generation, registration
  and cleanup deadline. It must retire the actual local transport workers and
  return an existing `ToolEffects.Cancellation` assertion. A remote operation's
  business outcome remains unknown. Missing or invalid retirement evidence keeps
  cancellation uncertain. Both callbacks execute outside the extension GenServer.
  """

  alias Backplane.AgentRuntime.{Error, ToolEffects}

  @encrypted_fields %{
    "history::search_contents" => "query",
    "notes::search_contents" => "query",
    "notes::append_to_file" => "text",
    "notes::write_file" => "text"
  }
  @default_output_limit 1_048_576

  @callback execute(map(), map(), term()) :: {:ok, map()} | {:error, Error.t()}
  @callback cancel(map(), map(), term()) ::
              {:ok, ToolEffects.Cancellation.t()} | {:error, Error.t()}

  @doc false
  def configure(nil), do: {:ok, nil}

  def configure(%{mode: :remote_encrypted, adapter: adapter, request_context: context} = config)
      when is_atom(adapter) and not is_nil(adapter) and is_map(context) do
    limit = Map.get(config, :output_limit, @default_output_limit)

    with true <- Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :execute, 3),
         true <- function_exported?(adapter, :cancel, 3),
         true <- nonempty_string?(context[:session_id]),
         true <- nonempty_string?(context[:current_agent_name]),
         true <- is_integer(limit) and limit > 0,
         {:ok, policy} <- policy(Map.get(config, :output_policy)) do
      {:ok,
       %{
         adapter: adapter,
         context: Map.get(config, :context, %{}),
         request_context: Map.take(context, [:session_id, :current_agent_name]),
         output_policy: policy,
         output_limit: limit
       }}
    else
      _ -> invalid_configuration()
    end
  end

  def configure(_), do: invalid_configuration()

  @doc false
  def schema(schema, tool, :remote_encrypted) when is_map_key(@encrypted_fields, tool),
    do: put_in(schema, ["properties", @encrypted_fields[tool], "encrypted"], true)

  def schema(schema, _tool, _mode), do: schema

  @doc false
  def call(operation, scope, config) do
    runtime = operation.backend_context.runtime

    with {:ok, registration, gate} <-
           GenServer.call(runtime, {:history_notes, {:register, operation}}) do
      operation =
        Map.put(operation, :history_notes_admission, %{registration: registration, gate: gate})

      case register_conversation(operation, registration) do
        :ok ->
          try do
            with :ok <- begin_request(gate) do
              request = request(operation, config)
              result = config.adapter.execute(request, scope, config.context)
              normalize_result(result, config.output_limit)
            end
          after
            :atomics.put(gate, 1, 2)

            if is_nil(operation.backend_context[:register_cancellation]),
              do: release(%{operation: operation, registration: registration})
          end

        error ->
          release(%{operation: operation, registration: registration})
          error
      end
    end
  end

  defp register_conversation(operation, registration) do
    case operation.backend_context[:register_cancellation] do
      register when is_function(register, 2) ->
        case register.(operation, registration) do
          {:ok, coordinator} when is_pid(coordinator) -> :ok
          {:error, %Error{} = error} -> {:error, error}
          _ -> unavailable("History/Notes cancellation registration failed")
        end

      nil ->
        :ok
    end
  end

  defp begin_request(gate) do
    if :atomics.compare_exchange(gate, 1, 0, 1) == :ok,
      do: :ok,
      else: {:error, Error.new(:cancelled, "History/Notes request was stopped before dispatch")}
  end

  @doc false
  def register_admission(operation, registration, coordinator, timeout) do
    GenServer.call(
      operation.backend_context.runtime,
      {:history_notes, {:admit, operation, registration, coordinator}},
      timeout
    )
  catch
    :exit, _ -> unavailable("History/Notes cancellation admission is unavailable")
  end

  @doc false
  def seal_admission(%{operation: %{history_notes_admission: %{gate: gate}}}) do
    :atomics.put(gate, 1, 2)
    :ok
  end

  @doc false
  def cancel(%{cleanup_deadline: deadline} = operation) when is_integer(deadline) do
    timeout = max(1, deadline - now())

    with {:ok, config, scope} <-
           GenServer.call(
             operation.backend_context.runtime,
             {:history_notes, {:cancel, operation}},
             timeout
           ),
         {:ok, assertion} <-
           config.adapter.cancel(request(operation, config), scope, config.context),
         {:ok, _} <- ToolEffects.validate_cancellation(assertion, operation) do
      {:ok, assertion}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> unavailable("History/Notes transport retirement is unverified")
    end
  catch
    :exit, _ -> unavailable("History/Notes cancellation acknowledgement unavailable")
  end

  def cancel(_), do: unavailable("History/Notes cancellation deadline is unavailable")

  @doc false
  def release(entry),
    do: GenServer.cast(entry.operation.backend_context.runtime, {:release_history_notes, entry})

  @doc false
  def handle({:register, operation}, {owner, _}, state) do
    registration = "history_notes_#{System.unique_integer([:positive, :monotonic])}"
    gate = :atomics.new(1, signed: false)

    entry = %{
      operation: operation,
      owner: owner,
      monitor: Process.monitor(owner),
      gate: gate,
      coordinator: nil,
      stop_generation: nil,
      cleanup_deadline: nil
    }

    {:reply, {:ok, registration, gate}, put_in(state.history_notes_requests[registration], entry)}
  end

  def handle({:admit, operation, registration, coordinator}, _from, state) do
    case fetch_entry(state, operation, registration) do
      {:ok, entry} ->
        if operation.backend_context[:cancellation_coordinator] === coordinator and
             get_in(operation, [:history_notes_admission, :gate]) === entry.gate do
          {:reply, :ok,
           put_in(state.history_notes_requests[registration], %{entry | coordinator: coordinator})}
        else
          {:reply, unavailable("History/Notes cancellation coordinator is stale"), state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle({:cancel, operation}, _from, state) do
    with {:ok, entry} <- fetch_entry(state, operation, operation[:resource_registration]),
         true <- entry.coordinator === operation.backend_context[:cancellation_coordinator],
         true <- is_binary(operation[:stop_generation]) and operation.stop_generation != "",
         true <- is_integer(operation[:cleanup_deadline]) and operation.cleanup_deadline > now(),
         true <- entry.stop_generation in [nil, operation.stop_generation],
         true <- entry.cleanup_deadline in [nil, operation.cleanup_deadline] do
      :atomics.put(entry.gate, 1, 2)

      entry = %{
        entry
        | stop_generation: operation.stop_generation,
          cleanup_deadline: operation.cleanup_deadline
      }

      {:reply, {:ok, state.history_notes, state.scope},
       put_in(state.history_notes_requests[operation.resource_registration], entry)}
    else
      _ -> {:reply, unavailable("History/Notes cancellation is stale"), state}
    end
  end

  @doc false
  def release_entry(state, %{operation: operation, registration: registration}) do
    case fetch_entry(state, operation, registration) do
      {:ok, entry} ->
        Process.demonitor(entry.monitor, [:flush])
        %{state | history_notes_requests: Map.delete(state.history_notes_requests, registration)}

      _ ->
        state
    end
  end

  @doc false
  def owner_down(state, monitor) do
    entries =
      Enum.reduce(state.history_notes_requests, %{}, fn {id, entry}, acc ->
        if entry.monitor === monitor do
          :atomics.put(entry.gate, 1, 2)
          if entry.coordinator, do: Map.put(acc, id, entry), else: acc
        else
          Map.put(acc, id, entry)
        end
      end)

    %{state | history_notes_requests: entries}
  end

  defp fetch_entry(state, operation, registration) do
    case state.history_notes_requests[registration] do
      %{operation: original} = entry ->
        if ToolEffects.cancellation_identity(original) ===
             ToolEffects.cancellation_identity(operation),
           do: {:ok, entry},
           else: unavailable("History/Notes invocation identity is stale")

      _ ->
        unavailable("History/Notes registration is unavailable")
    end
  end

  defp request(operation, config) do
    [namespace, name] = String.split(operation.tool_name, "::", parts: 2)

    headers = %{"x-openai-tool-output-truncation-policy" => config.output_policy}

    headers =
      if Map.has_key?(@encrypted_fields, operation.tool_name),
        do: Map.put(headers, "x-openai-encrypted-tool-arguments", "true"),
        else: headers

    Map.put(operation, :history_notes_request, %{
      path: "alpha/#{namespace}/v2/#{name}",
      body:
        Map.put(
          operation.arguments,
          "context",
          Map.new(config.request_context, fn {key, value} -> {Atom.to_string(key), value} end)
        ),
      headers: headers
    })
  end

  defp normalize_result({:ok, result}, limit) when is_map(result) do
    with :ok <- bounded(result, limit),
         {:ok, first} <- output_content(Map.delete(result, "images")),
         {:ok, images} <- images(Map.get(result, "images", [])),
         content = [first | images],
         :ok <- bounded(content, limit) do
      {:ok, %{content: content}}
    end
  end

  defp normalize_result({:error, %Error{} = error}, _limit), do: {:error, error}

  defp normalize_result(_, _limit),
    do: {:error, Error.new(:malformed_result, "History/Notes backend result must be an object")}

  defp output_content(%{"encrypted_output" => encrypted}) do
    if nonempty_string?(encrypted),
      do: {:ok, %{type: :encrypted_content, data: %{"encrypted_content" => encrypted}}},
      else:
        {:error,
         Error.new(:malformed_result, "History/Notes encrypted_output must be a nonempty string")}
  end

  defp output_content(result) do
    {:ok, %{type: :text, text: JSON.encode!(result)}}
  rescue
    _ ->
      {:error,
       Error.new(:malformed_result, "History/Notes backend result must contain JSON data")}
  end

  defp bounded(result, limit) do
    if :erlang.external_size(result) <= limit,
      do: :ok,
      else:
        {:error,
         Error.new(:budget_exceeded, "History/Notes result exceeds its output bound",
           details: %{limit: limit}
         )}
  end

  defp images(images) when is_list(images) do
    Enum.reduce_while(images, {:ok, []}, fn
      %{"data" => data, "mime_type" => mime} = image, {:ok, acc}
      when is_binary(data) and is_binary(mime) ->
        if nonempty_string?(data) and mime in ~w(image/png image/jpeg image/webp image/gif) and
             Map.get(image, "detail", "auto") in [nil | ~w(auto low high original)] do
          data =
            image
            |> Map.take(["data", "mime_type", "detail"])
            |> Map.reject(fn {_key, value} -> is_nil(value) end)

          {:cont, {:ok, [%{type: :image, data: data} | acc]}}
        else
          {:halt, invalid_images()}
        end

      _, _ ->
        {:halt, invalid_images()}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp images(_), do: invalid_images()

  defp invalid_images,
    do: {:error, Error.new(:malformed_result, "History/Notes backend returned invalid images")}

  defp policy(%{"mode" => mode, "limit" => limit} = policy)
       when map_size(policy) == 2 and mode in ["bytes", "tokens"] and
              is_integer(limit) and limit >= 0,
       do: {:ok, JSON.encode!(policy)}

  defp policy(_), do: invalid_configuration()
  defp nonempty_string?(value), do: is_binary(value) and value != "" and String.valid?(value)
  defp now, do: System.monotonic_time(:millisecond)
  defp unavailable(message), do: {:error, Error.new(:unknown_outcome, message)}

  defp invalid_configuration,
    do:
      {:error,
       Error.new(
         :validation,
         "remote encrypted History/Notes requires an explicit adapter, session, agent and output policy"
       )}
end
