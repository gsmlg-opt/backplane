defmodule Backplane.LLM.ProtocolRouteTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.{ProtocolRoute, ProviderApi}

  test "selects native passthrough only for the exact client wire protocol" do
    api = %ProviderApi{
      api_surface: :openai,
      native_protocols: [:openai_chat_completions, :openai_responses]
    }

    assert {:ok, :native} = ProtocolRoute.select(:openai_responses, api)
    assert {:ok, :native} = ProtocolRoute.select(:openai_chat_completions, api)
  end

  test "rejects an unavailable cross-protocol route before forwarding" do
    api = %ProviderApi{
      api_surface: :openai,
      native_protocols: [:openai_responses]
    }

    assert {:error,
            {:unsupported_translation, :openai_chat_completions, [:openai_responses]}} =
             ProtocolRoute.select(:openai_chat_completions, api)
  end

  test "identifies client protocol from the concrete endpoint" do
    assert ProtocolRoute.client_protocol("/v1/responses") == :openai_responses
    assert ProtocolRoute.client_protocol("/v1/chat/completions") == :openai_chat_completions
    assert ProtocolRoute.client_protocol("/v1/messages") == :anthropic_messages
  end
end
