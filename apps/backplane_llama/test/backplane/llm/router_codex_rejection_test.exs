defmodule Backplane.LLM.RouterCodexRejectionTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    Router
  }

  alias Backplane.Settings.Credentials

  setup do
    expires_at = System.system_time(:millisecond) + 60 * 60 * 1000

    {:ok, _} =
      Credentials.store_device_token(
        "codex-rejection-token",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "access_token" => "chatgpt-access-token",
          "refresh_token" => "refresh-token",
          "expires_at" => expires_at
        },
        %{"account_id" => "acc-123"}
      )

    {:ok, provider} =
      Provider.create(%{
        name: "codex-rejection",
        preset_key: "openai-codex",
        api_type: :openai,
        api_url: "https://chatgpt.com/backend-api/codex",
        credential: "codex-rejection-token",
        models: []
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://chatgpt.com/backend-api/codex"
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "gpt-5.5", source: :discovered})

    ProviderModelSurface.create(%{provider_model_id: model.id, provider_api_id: api.id})
    ModelResolver.clear_cache()
    %{provider: provider, model: model.model}
  end

  test "rejects Codex Chat Completions locally" do
    conn =
      Plug.Test.conn(
        :post,
        "/v1/chat/completions",
        Jason.encode!(%{
          model: "codex-rejection/gpt-5.5",
          messages: []
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 400
    assert conn.resp_body =~ "codex_requires_responses_api"
  end
end
