defmodule Backplane.AgentRuntime.ProviderSelection do
  @moduledoc false
  alias Backplane.AgentRuntime.Error

  @request_limit 64
  @intent_limit 16_384
  @view_limit 1_048_576
  @identity [:run_id, :incarnation, :turn_id]
  @attempt [:run_id, :incarnation, :step_id, :attempt_id]

  def initial(nil, enabled),
    do: %{
      enabled: enabled,
      generation: 0,
      pending: nil,
      receipts: %{},
      binding: nil,
      view: nil,
      boundary: nil
    }

  def initial(binding, enabled),
    do: Map.put(initial(nil, enabled), :binding, Map.take(binding, [:provider, :model]))

  def validate_initial(nil), do: :ok

  def validate_initial(binding) do
    if valid_binding?(binding) and not is_struct(binding) and
         Enum.sort(Map.keys(binding)) == [:model, :provider],
       do: :ok,
       else: invalid("provider_selection accepts only provider and model text")
  end

  def state(run), do: Map.get(run, :provider_selection_state, initial(nil, false))
  def enabled?(run), do: state(run).enabled

  def stage(run, input) do
    selection = state(run)
    request = Map.get(input, :request)
    turn = get_in(run, [:context, :conversation, :turn_id])

    with true <- selection.enabled,
         true <- is_map(request) and not is_struct(request) and not is_nil(turn),
         true <-
           Enum.sort(Map.keys(request)) == Enum.sort(@identity ++ [:request_id, :mode, :intent]),
         true <- portable?(request, 0) and :erlang.external_size(request) <= @intent_limit,
         true <-
           Map.take(request, @identity) == %{
             run_id: run.run_id,
             incarnation: run.incarnation,
             turn_id: turn
           },
         true <- text?(request[:request_id]) and request[:mode] in [:select, :reset],
         true <- is_map(request[:intent]) and portable?(request.intent, 0),
         true <- :erlang.external_size(request.intent) <= @intent_limit,
         true <- request.mode != :reset or request.intent == %{} do
      case Map.get(selection.receipts, request.request_id) do
        %{request: ^request} -> {:ok, run}
        nil -> stage_new(run, selection, request)
        _ -> conflict("selection request identity was reused with different content")
      end
    else
      _ ->
        invalid(
          "provider selection requires an enabled live turn and a bounded correlated request"
        )
    end
  end

  defp stage_new(run, selection, request) do
    if map_size(selection.receipts) < @request_limit do
      generation = selection.generation + 1
      receipt = %{request: request, generation: generation, revision: run.expected_revision + 1}

      next = %{
        selection
        | generation: generation,
          pending: receipt,
          receipts: Map.put(selection.receipts, request.request_id, receipt)
      }

      {:ok, Map.put(run, :provider_selection_state, next)}
    else
      invalid("provider selection request ledger is full")
    end
  end

  def receipt(run, id), do: Map.get(state(run).receipts, id)

  def blocking_event?(%{type: type}),
    do:
      type in [
        :content_text_delta,
        :content_thinking_delta,
        :tool_call_started,
        :tool_call_arguments_delta,
        :tool_call_completed,
        :provider_hosted_event,
        :response_completed
      ]

  def blocked?(run, attempt),
    do: get_in(run, [:provider_attempts, attempt, :replay_blocked]) == true

  def block(run, input) do
    identity = Map.take(input, @attempt)

    if enabled?(run) and Map.get(run, :active_provider) == identity do
      {:ok, put_in(run, [:provider_attempts, identity.attempt_id, :replay_blocked], true)}
    else
      conflict("replay marker requires the active native provider attempt")
    end
  end

  def open(run, input) do
    selection = state(run)
    failed = Map.get(input, :failed_attempt)
    failure = Map.get(run, :last_provider_result, %{})
    messages = get_in(run, [:context, :conversation, :messages]) || []
    pending = selection.pending

    with true <- selection.enabled and is_map(pending),
         true <- is_map(failed) and is_nil(Map.get(run, :active_provider)),
         true <-
           Map.take(failed, [:run_id, :incarnation]) == Map.take(run, [:run_id, :incarnation]),
         attempt when is_map(attempt) <- get_in(run, [:provider_attempts, failed[:attempt_id]]),
         true <- Map.take(attempt, @attempt) == failed,
         true <- attempt[:turn_id] == input[:turn_id] and not is_nil(input[:turn_id]),
         true <- input[:turn_id] == get_in(run, [:context, :conversation, :turn_id]),
         true <-
           Map.take(run.current_step || %{}, [:step_id, :attempt_id]) ==
             Map.take(failed, [:step_id, :attempt_id]),
         true <- failure[:recovery] in [:retry, :compaction] and Map.has_key?(failure, :error),
         true <- not blocked?(run, failed.attempt_id),
         true <- text?(input[:boundary_id]),
         true <- input[:turn_id] == pending.request.turn_id,
         true <- selection.boundary == nil do
      boundary = %{
        id: input.boundary_id,
        failed_attempt: failed,
        reason: failure.recovery,
        selection: pending,
        turn_id: input.turn_id,
        prefix_count: length(messages),
        prefix_digest: digest(messages)
      }

      {:ok, Map.put(run, :provider_selection_state, %{selection | boundary: boundary})}
    else
      _ -> conflict("provider attempt is not eligible for selection recovery")
    end
  end

  def provider_start(run, input) do
    selection = state(run)
    adoption = input[:provider_adoption]

    cond do
      is_nil(adoption) and is_nil(selection.boundary) -> {:ok, run}
      is_nil(adoption) -> conflict("open recovery boundary requires its pinned adoption")
      true -> adopt(run, input, selection, adoption)
    end
  end

  defp adopt(run, input, selection, adoption) do
    boundary = selection.boundary
    canonical = get_in(run, [:context, :conversation, :messages]) || []

    with true <- is_map(boundary) and is_map(adoption),
         true <- adoption[:boundary_id] == boundary.id,
         true <- adoption[:request_id] == boundary.selection.request.request_id,
         true <- adoption[:generation] == boundary.selection.generation,
         true <- adoption[:turn_id] == boundary.turn_id and input[:turn_id] == boundary.turn_id,
         true <- valid_binding?(adoption),
         true <- same_prefix?(canonical, boundary),
         {:ok, view} <- validate_view(input[:provider_view], canonical, boundary) do
      binding = Map.take(adoption, [:provider, :model, :request_id, :generation, :turn_id])

      pending =
        if selection.pending && selection.pending.generation == boundary.selection.generation,
          do: nil,
          else: selection.pending

      next = %{selection | binding: binding, pending: pending, boundary: nil, view: view}
      {:ok, Map.put(run, :provider_selection_state, next)}
    else
      _ -> conflict("provider adoption does not match its native recovery boundary")
    end
  end

  def prepare_result({:ok, result}, boundary, messages) when is_map(result) do
    with true <- valid_binding?(result),
         true <- is_map(Map.get(result, :provider_context, %{})),
         {:ok, view} <- prepared_view(Map.get(result, :messages, :unchanged), boundary, messages) do
      adoption = %{
        provider: result.provider,
        model: result.model,
        boundary_id: boundary.id,
        request_id: boundary.selection.request.request_id,
        generation: boundary.selection.generation,
        turn_id: boundary.turn_id
      }

      {:ok, adoption, view, Map.get(result, :provider_context, %{})}
    else
      _ -> invalid("provider selection preparation returned an invalid binding or message view")
    end
  end

  def prepare_result({:error, %Error{} = error}, _boundary, _messages), do: {:error, error}

  def prepare_result(_, _, _),
    do: invalid("provider selection preparation returned an invalid result")

  defp prepared_view(:unchanged, _boundary, _messages), do: {:ok, nil}

  defp prepared_view(messages, boundary, _canonical) when is_list(messages) do
    if valid_messages?(messages) do
      {:ok,
       %{
         messages: messages,
         prefix_count: boundary.prefix_count,
         prefix_digest: boundary.prefix_digest
       }}
    else
      invalid("prepared provider messages exceed the portable view bound")
    end
  end

  defp prepared_view(_, _, _),
    do: invalid("prepared provider messages must be a message list or unchanged")

  defp validate_view(nil, _canonical, _boundary), do: {:ok, nil}

  defp validate_view(view, canonical, boundary) when is_map(view) do
    if view[:prefix_count] == boundary.prefix_count and
         view[:prefix_digest] == boundary.prefix_digest and
         valid_messages?(view[:messages]) and same_prefix?(canonical, view),
       do: {:ok, view},
       else: invalid("provider view does not match canonical history")
  end

  defp validate_view(_, _, _), do: invalid("provider view is invalid")

  def messages(run, canonical) do
    case state(run).view do
      nil ->
        {:ok, canonical}

      view ->
        if same_prefix?(canonical, view),
          do: {:ok, view.messages ++ Enum.drop(canonical, view.prefix_count)},
          else: conflict("canonical history no longer matches its prepared provider view")
    end
  end

  def clear_view_on_context_reset(run, conversation) do
    previous = get_in(run, [:context, :conversation, :context_window]) || 1

    if (Map.get(conversation, :context_window) || 1) != previous do
      Map.put(run, :provider_selection_state, %{state(run) | view: nil})
    else
      run
    end
  end

  def attempt_record(run, input, identity) do
    if enabled?(run) or state(run).binding do
      identity
      |> Map.put(:turn_id, input[:turn_id])
      |> Map.put(:provider_selection, state(run).binding)
      |> Map.put(:replay_blocked, false)
    else
      identity
    end
  end

  defp same_prefix?(messages, %{prefix_count: count, prefix_digest: expected})
       when is_list(messages) and is_integer(count) and count >= 0 do
    length(messages) >= count and digest(Enum.take(messages, count)) == expected
  end

  defp same_prefix?(_, _), do: false

  defp valid_messages?(messages) when is_list(messages) do
    :erlang.external_size(messages) <= @view_limit and portable?(messages, 0) and
      Enum.all?(messages, fn message ->
        is_map(message) and message[:role] in [:system, :developer, :user, :assistant, :tool] and
          (is_binary(message[:content]) or is_list(message[:content]) or
             (message[:role] == :tool and is_map(message[:result])))
      end)
  end

  defp valid_messages?(_), do: false

  defp valid_binding?(binding) when is_map(binding),
    do: text?(binding[:provider]) and text?(binding[:model])

  defp valid_binding?(_), do: false
  defp text?(value), do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp digest(messages),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(messages, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp portable?(_value, depth) when depth > 32, do: false
  defp portable?(value, _depth) when is_binary(value), do: String.valid?(value)
  defp portable?(value, _depth) when is_number(value) or is_atom(value), do: true

  defp portable?(value, depth) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} ->
        (is_binary(key) or is_atom(key)) and portable?(key, depth + 1) and
          portable?(item, depth + 1)
      end)

  defp portable?(value, depth) when is_list(value), do: portable_list?(value, depth + 1)
  defp portable?(_, _), do: false
  defp portable_list?([], _depth), do: true

  defp portable_list?([head | tail], depth),
    do: portable?(head, depth) and portable_list?(tail, depth)

  defp portable_list?(_, _), do: false
  defp invalid(message), do: {:error, Error.new(:validation, message)}
  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}
end
