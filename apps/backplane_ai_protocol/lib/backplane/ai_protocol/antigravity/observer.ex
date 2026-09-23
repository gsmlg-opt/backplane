defmodule Backplane.AiProtocol.Antigravity.Observer do
  @moduledoc """
  Bounded, non-disruptive observer for Antigravity native generation responses.

  Antigravity wraps Google GenerateContent documents in a `response` object.
  This observer unwraps only its private observation copy; callers continue to
  forward the original bytes unchanged.
  """

  alias Backplane.AiProtocol.{GoogleGenerateContentObserver, Serialization, SSE}

  defstruct framer: nil,
            google: nil,
            max_total_bytes: 8_388_608,
            max_events: 10_000,
            bytes_seen: 0,
            events_seen: 0,
            malformed?: false,
            terminal?: false

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      framer: SSE.new(opts),
      google: GoogleGenerateContentObserver.new(Keyword.put(opts, :operation, :generate)),
      max_total_bytes: positive(opts[:max_total_bytes], 8_388_608),
      max_events: positive(opts[:max_events], 10_000)
    }
  end

  @spec feed(t(), term()) :: t()
  def feed(%__MODULE__{terminal?: true} = state, _chunk), do: state

  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    bytes_seen = state.bytes_seen + byte_size(chunk)

    if bytes_seen > state.max_total_bytes do
      %{state | bytes_seen: bytes_seen, malformed?: true, terminal?: true}
    else
      case SSE.feed(state.framer, chunk) do
        {:ok, framer, events} ->
          observe_events(%{state | framer: framer, bytes_seen: bytes_seen}, events)

        {:error, _error, framer} ->
          %{state | framer: framer, bytes_seen: bytes_seen, malformed?: true}
      end
    end
  rescue
    _ -> %{state | malformed?: true}
  end

  def feed(%__MODULE__{} = state, _chunk), do: %{state | malformed?: true}

  @spec finish(t(), atom()) :: t()
  def finish(%__MODULE__{google: %{transport_terminal: terminal}} = state, _reason)
      when not is_nil(terminal),
      do: state

  def finish(%__MODULE__{} = state, reason) do
    state =
      if state.terminal? do
        state
      else
        case SSE.finish(state.framer) do
          {:ok, framer, events} -> observe_events(%{state | framer: framer}, events)
          {:error, _error, framer} -> %{state | framer: framer, malformed?: true}
        end
      end

    google =
      state.google
      |> mark_malformed(state.malformed?)
      |> GoogleGenerateContentObserver.finish(reason)

    %{state | google: google, terminal?: true}
  rescue
    _ -> %{state | malformed?: true, terminal?: true}
  end

  @spec facts(t()) :: map()
  def facts(%__MODULE__{} = state) do
    facts = GoogleGenerateContentObserver.facts(state.google)

    facts
    |> Map.put(:implementation, __MODULE__)
    |> Map.put(:source, :google_antigravity)
    |> Map.put(:bytes_seen, state.bytes_seen)
    |> Map.put(:events_seen, state.events_seen)
    |> maybe_incomplete(state)
  end

  @spec observe_response(non_neg_integer(), binary(), keyword()) :: map()
  def observe_response(status, body, opts \\ []) when is_integer(status) and is_binary(body) do
    max = positive(opts[:max_total_bytes], 8_388_608)

    facts =
      with true <- byte_size(body) <= max,
           {:ok, document} <- Serialization.from_json(body, max_encoded_bytes: max),
           true <- is_map(document),
           {:ok, observed} <- observation_document(document),
           {:ok, encoded} <- Jason.encode(observed) do
        GoogleGenerateContentObserver.observe_response(status, encoded, opts)
      else
        _ -> GoogleGenerateContentObserver.observe_response(status, body, opts)
      end

    facts
    |> Map.put(:implementation, __MODULE__)
    |> Map.put(:source, :google_antigravity)
    |> Map.put(:bytes_seen, byte_size(body))
  rescue
    _ ->
      GoogleGenerateContentObserver.observe_response(status, "", opts)
      |> Map.put(:implementation, __MODULE__)
      |> Map.put(:source, :google_antigravity)
      |> Map.put(:bytes_seen, byte_size(body))
  end

  defp observe_events(state, events) do
    if state.events_seen + length(events) > state.max_events do
      %{state | malformed?: true, terminal?: true}
    else
      google = Enum.reduce(events, state.google, &observe_event/2)
      %{state | google: google, events_seen: state.events_seen + length(events)}
    end
  end

  defp observe_event(%{data: data}, google) do
    with {:ok, document} <- Serialization.from_json(data),
         true <- is_map(document),
         {:ok, observed} <- observation_document(document),
         {:ok, encoded} <- Jason.encode(observed) do
      GoogleGenerateContentObserver.feed(google, "data: " <> encoded <> "\n\n")
    else
      _ -> GoogleGenerateContentObserver.feed(google, "data: {invalid}\n\n")
    end
  end

  defp observation_document(%{"response" => response}) when is_map(response), do: {:ok, response}
  defp observation_document(document) when is_map(document), do: {:ok, document}

  defp mark_malformed(google, false), do: google

  defp mark_malformed(google, true),
    do: GoogleGenerateContentObserver.feed(google, "data: {invalid}\n\n")

  defp maybe_incomplete(facts, %{malformed?: false}), do: facts

  defp maybe_incomplete(facts, _state) do
    facts
    |> Map.put(:observation_status, :incomplete)
    |> Map.put(:partial, true)
    |> Map.update(:protocol_terminal, :incomplete, fn
      terminal when terminal in [:failed, :cancelled] -> terminal
      _ -> :incomplete
    end)
    |> Map.update(:transport_terminal, :failed, fn
      nil -> :failed
      terminal -> terminal
    end)
    |> Map.update(:diagnostics, ["antigravity_observer_error"], fn diagnostics ->
      if "antigravity_observer_error" in diagnostics,
        do: diagnostics,
        else: diagnostics ++ ["antigravity_observer_error"]
    end)
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
