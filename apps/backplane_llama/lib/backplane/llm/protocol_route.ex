defmodule Backplane.LLM.ProtocolRoute do
  @moduledoc """
  Selects the LLM execution path from concrete client and upstream wire protocols.

  Exact matches are native passthrough. A mismatch is an explicit translation
  boundary; until a complete request, response, stream, and error codec exists
  for that directed pair, selection fails before contacting the upstream.
  """

  alias Backplane.LLM.ProviderApi

  @type protocol ::
          :openai_chat_completions
          | :openai_responses
          | :anthropic_messages
          | :google_generate_content
          | :google_antigravity

  @spec client_protocol(String.t()) :: protocol() | :unknown
  def client_protocol("/v1/responses"), do: :openai_responses
  def client_protocol("/v1/chat/completions"), do: :openai_chat_completions
  def client_protocol("/v1/messages"), do: :anthropic_messages

  def client_protocol("/v1/" <> rest) do
    client_protocol("/" <> rest)
  end

  def client_protocol(_path), do: :unknown

  @spec select(protocol(), ProviderApi.t()) ::
          {:ok, :native | {:translate, :google_to_antigravity}}
          | {:error, {:unsupported_translation, protocol(), [protocol()]}}
  def select(client_protocol, %ProviderApi{native_protocols: native_protocols})
      when client_protocol in [
             :openai_chat_completions,
             :openai_responses,
             :anthropic_messages,
             :google_generate_content,
             :google_antigravity
           ] and is_list(native_protocols) do
    cond do
      client_protocol in native_protocols ->
        {:ok, :native}

      client_protocol == :google_generate_content and :google_antigravity in native_protocols ->
        {:ok, {:translate, :google_to_antigravity}}

      true ->
        {:error, {:unsupported_translation, client_protocol, native_protocols}}
    end
  end
end
