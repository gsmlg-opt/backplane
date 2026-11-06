defmodule Backplane.LLM.ResponsesWebsocketConfigTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.ProviderApi

  defp changeset(attrs) do
    ProviderApi.changeset(
      %ProviderApi{},
      Map.merge(
        %{
          provider_id: "00000000-0000-0000-0000-000000000001",
          api_surface: :openai,
          base_url: "https://api.example.com/v1",
          native_protocols: [:openai_responses]
        },
        attrs
      )
    )
  end

  test "default off and independent of lifecycle" do
    for lifecycle <- [false, true] do
      changeset = changeset(%{responses_lifecycle: lifecycle})
      assert changeset.valid?
      refute Ecto.Changeset.get_field(changeset, :responses_websocket)
    end

    changeset = changeset(%{responses_websocket: true})
    assert changeset.valid?
    refute Ecto.Changeset.get_field(changeset, :responses_lifecycle)
  end

  test "requires native Responses and a nonnull boolean" do
    for attrs <- [
          %{native_protocols: [:openai_chat_completions], responses_websocket: true},
          %{
            api_surface: :anthropic,
            native_protocols: [:anthropic_messages],
            responses_websocket: true
          },
          %{responses_websocket: nil},
          %{responses_websocket: "yes"}
        ] do
      changeset = changeset(attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :responses_websocket)
    end
  end

  test "removing native Responses requires disabling its WebSocket declaration" do
    api = changeset(%{responses_websocket: true}) |> Ecto.Changeset.apply_changes()
    attrs = %{native_protocols: [:openai_chat_completions]}
    refute ProviderApi.changeset(api, attrs).valid?
    assert ProviderApi.changeset(api, Map.put(attrs, :responses_websocket, false)).valid?
  end
end
