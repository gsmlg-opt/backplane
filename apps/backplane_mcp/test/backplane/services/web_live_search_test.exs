defmodule Backplane.Services.WebLiveSearchTest do
  use Backplane.DataCase, async: false

  alias Backplane.LLM.{
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    RateLimiter
  }

  alias Backplane.Services.{Web, WebLiveSearch}
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  setup do
    previous = Application.get_env(:backplane, :web_live_search_req_options)

    Application.put_env(:backplane, :web_live_search_req_options, plug: {Req.Test, WebLiveSearch})

    Settings.set("services.web.enabled", true)
    Settings.set("services.web_live_search.models", [])
    Settings.set("services.web_live_search.model", nil)
    ModelResolver.clear_cache()
    RateLimiter.reset()

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :web_live_search_req_options, previous)
      else
        Application.delete_env(:backplane, :web_live_search_req_options)
      end
    end)

    :ok
  end

  test "web service exposes web::live_search with ManagedService-shaped fields" do
    tool = live_search_tool()

    assert tool.name == "web::live_search"
    assert is_binary(tool.description)
    assert is_map(tool.input_schema)
    assert is_function(tool.handler, 1)

    assert Map.keys(tool.input_schema["properties"]) == ["query"]

    assert tool.input_schema["required"] == ["query"]
    assert tool.input_schema["additionalProperties"] == false
  end

  test "web::live_search calls the resolved OpenAI-compatible Responses API with web_search" do
    create_openai_model("openai-live", "gpt-5.5", preset_key: "openai")
    Settings.set("services.web_live_search.models", ["openai-live/gpt-5.5"])

    Req.Test.stub(WebLiveSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/v1/responses"
      assert {"authorization", "Bearer live-secret"} in conn.req_headers

      decoded = Jason.decode!(body)
      assert decoded["model"] == "gpt-5.5"
      assert decoded["input"] == [%{"role" => "user", "content" => "latest elixir release"}]
      refute Map.has_key?(decoded, "instructions")
      assert decoded["tools"] == [%{"type" => "web_search"}]
      assert decoded["store"] == false
      refute Map.has_key?(decoded, "max_output_tokens")

      Req.Test.json(conn, %{
        "id" => "resp_live_1",
        "model" => "gpt-5.5",
        "output" => [
          %{
            "type" => "web_search_call",
            "status" => "completed"
          },
          %{
            "type" => "message",
            "content" => [
              %{
                "type" => "output_text",
                "text" => "Elixir has a current release.",
                "annotations" => [
                  %{
                    "type" => "url_citation",
                    "url" => "https://elixir-lang.org/blog/",
                    "title" => "Elixir blog"
                  }
                ]
              }
            ]
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      })
    end)

    assert {:ok, result} =
             live_search_tool().handler.(%{
               "query" => " latest elixir release "
             })

    assert Map.keys(result) |> Enum.sort() == ["query", "results", "usage"]
    assert result["query"] == "latest elixir release"

    assert [
             %{
               "provider" => "openai-live",
               "model" => "gpt-5.5",
               "title" => "Live search answer",
               "url" => "",
               "snippet" => "Elixir has a current release."
             }
           ] = result["results"]

    assert [
             %{
               "provider" => "openai-live",
               "model" => "gpt-5.5",
               "input_tokens" => 10,
               "output_tokens" => 20
             }
           ] = result["usage"]
  end

  test "web::live_search streams OpenAI Codex OAuth Responses requests" do
    credential_name = "openai-codex-live-cred"
    expires_at = System.system_time(:millisecond) + 60 * 60 * 1000

    {:ok, _} =
      Credentials.store_device_token(
        credential_name,
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "auth_mode" => "chatgpt",
          "id_token" => "codex-id-token",
          "access_token" => "codex-oauth-token",
          "refresh_token" => "refresh-token",
          "expires_at" => expires_at
        },
        %{"account_id" => "acc-live"}
      )

    {:ok, provider} =
      Provider.create(%{
        name: "openai-codex-live",
        credential: credential_name,
        preset_key: "openai-codex"
      })

    {:ok, _api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.openai.com/v1"
      })

    Settings.set("services.web_live_search.models", ["openai-codex-live/gpt-5.5"])

    Req.Test.stub(WebLiveSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/backend-api/codex/responses"
      assert {"authorization", "Bearer codex-oauth-token"} in conn.req_headers

      decoded = Jason.decode!(body)
      assert decoded["model"] == "gpt-5.5"
      assert decoded["stream"] == true
      assert decoded["instructions"] =~ "hosted web search"
      refute Map.has_key?(decoded, "max_output_tokens")
      assert decoded["tools"] == [%{"type" => "web_search"}]

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.join(
          [
            sse_event(%{"type" => "response.output_text.delta", "delta" => "Codex "}),
            sse_event(%{"type" => "response.output_text.delta", "delta" => "live answer."}),
            sse_event(%{
              "type" => "response.completed",
              "response" => %{
                "usage" => %{"input_tokens" => 3, "output_tokens" => 4},
                "output" => [
                  %{
                    "type" => "message",
                    "content" => [
                      %{
                        "type" => "output_text",
                        "text" => "Codex live answer.",
                        "annotations" => [
                          %{
                            "type" => "url_citation",
                            "url" => "https://example.com/live"
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            })
          ],
          ""
        )
      )
    end)

    assert {:ok, result} =
             live_search_tool().handler.(%{
               "query" => "current codex result"
             })

    assert Map.keys(result) |> Enum.sort() == ["query", "results", "usage"]
    assert result["query"] == "current codex result"

    assert [
             %{
               "provider" => "openai-codex-live",
               "model" => "gpt-5.5",
               "title" => "Live search answer",
               "url" => "",
               "snippet" => "Codex live answer."
             }
           ] = result["results"]

    assert [
             %{
               "provider" => "openai-codex-live",
               "model" => "gpt-5.5",
               "input_tokens" => 3,
               "output_tokens" => 4
             }
           ] = result["usage"]
  end

  test "web::live_search runs every configured live search model in order" do
    create_openai_model("openai-live", "gpt-5.5", preset_key: "openai")

    create_openai_model("xai-live", "grok-4.3",
      preset_key: "x-ai",
      base_url: "https://api.x.ai/v1"
    )

    Settings.set("services.web_live_search.models", ["xai-live/grok-4.3", "openai-live/gpt-5.5"])

    Req.Test.stub(WebLiveSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body)["model"] do
        "grok-4.3" ->
          Req.Test.json(conn, %{
            "id" => "resp_live_default_xai",
            "model" => "grok-4.3",
            "output_text" => "Configured xAI result",
            "usage" => %{"input_tokens" => 11, "output_tokens" => 12}
          })

        "gpt-5.5" ->
          Req.Test.json(conn, %{
            "id" => "resp_live_default_openai",
            "model" => "gpt-5.5",
            "output_text" => "Configured OpenAI result",
            "usage" => %{"input_tokens" => 21, "output_tokens" => 22}
          })
      end
    end)

    assert {:ok, result} =
             live_search_tool().handler.(%{
               "query" => "current search result"
             })

    assert Map.keys(result) |> Enum.sort() == ["query", "results", "usage"]
    assert result["query"] == "current search result"

    assert [
             %{
               "provider" => "xai-live",
               "model" => "grok-4.3",
               "snippet" => "Configured xAI result"
             },
             %{
               "provider" => "openai-live",
               "model" => "gpt-5.5",
               "snippet" => "Configured OpenAI result"
             }
           ] = result["results"]

    assert [
             %{
               "provider" => "xai-live",
               "model" => "grok-4.3",
               "input_tokens" => 11,
               "output_tokens" => 12
             },
             %{
               "provider" => "openai-live",
               "model" => "gpt-5.5",
               "input_tokens" => 21,
               "output_tokens" => 22
             }
           ] = result["usage"]
  end

  test "web::live_search resolves configured fallback models without discovered model rows" do
    create_openai_provider("xai-live",
      preset_key: "x-ai",
      base_url: "https://api.x.ai/v1"
    )

    Settings.set("services.web_live_search.models", ["xai-live/grok-4.3"])

    Req.Test.stub(WebLiveSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body)["model"] == "grok-4.3"

      Req.Test.json(conn, %{
        "id" => "resp_live_fallback",
        "model" => "grok-4.3",
        "output_text" => "Fallback model result",
        "usage" => %{}
      })
    end)

    assert {:ok, result} =
             live_search_tool().handler.(%{
               "query" => "current search result"
             })

    assert Map.keys(result) |> Enum.sort() == ["query", "results", "usage"]
    assert result["query"] == "current search result"

    assert [
             %{
               "provider" => "xai-live",
               "model" => "grok-4.3",
               "title" => "Live search answer",
               "url" => "",
               "snippet" => "Fallback model result"
             }
           ] = result["results"]

    assert [
             %{
               "provider" => "xai-live",
               "model" => "grok-4.3"
             }
           ] = result["usage"]
  end

  test "web::live_search ignores caller supplied model and tuning params" do
    create_openai_model("openai-live", "gpt-5.5", preset_key: "openai")

    create_openai_model("xai-live", "grok-4.3",
      preset_key: "x-ai",
      base_url: "https://api.x.ai/v1"
    )

    Settings.set("services.web_live_search.models", ["openai-live/gpt-5.5"])

    Req.Test.stub(WebLiveSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      decoded = Jason.decode!(body)
      assert decoded["model"] == "gpt-5.5"
      assert decoded["tools"] == [%{"type" => "web_search"}]
      refute Map.has_key?(decoded, "instructions")
      refute Map.has_key?(decoded, "max_output_tokens")

      Req.Test.json(conn, %{
        "id" => "resp_live_ignored_params",
        "model" => "gpt-5.5",
        "output_text" => "Managed settings selected the model.",
        "usage" => %{}
      })
    end)

    assert {:ok, result} =
             live_search_tool().handler.(%{
               "query" => "current search result",
               "model" => "xai-live/grok-4.3",
               "instructions" => "Use caller instructions",
               "tool_type" => "web_search_preview",
               "search_context_size" => "high",
               "max_output_tokens" => 1
             })

    assert Map.keys(result) |> Enum.sort() == ["query", "results", "usage"]
    assert result["query"] == "current search result"

    assert [
             %{
               "provider" => "openai-live",
               "model" => "gpt-5.5"
             }
           ] = result["results"]

    assert [
             %{
               "provider" => "openai-live",
               "model" => "gpt-5.5"
             }
           ] = result["usage"]
  end

  test "web::live_search rejects OpenAI-compatible providers without hosted web_search support" do
    create_openai_model("compatible-live", "gpt-4o",
      preset_key: "openrouter",
      base_url: "https://openrouter.ai/api/v1"
    )

    Settings.set("services.web_live_search.models", ["compatible-live/gpt-4o"])

    assert {:error, %{code: "web_live_search_error", message: message}} =
             live_search_tool().handler.(%{
               "query" => "current search result"
             })

    assert message ==
             "compatible-live does not support hosted web_search for web::live_search"
  end

  test "web::live_search reports missing OpenAI-compatible model configuration" do
    assert {:error, %{code: "web_live_search_error", message: message}} =
             live_search_tool().handler.(%{"query" => "current news"})

    assert message =~ "no OpenAI-compatible LLM provider"
  end

  defp live_search_tool do
    Enum.find(Web.tools(), &(&1.name == "web::live_search")) ||
      flunk("expected web::live_search to be registered")
  end

  defp sse_event(event), do: "data: #{Jason.encode!(event)}\n\n"

  defp create_openai_model(provider_name, model_id, opts) do
    provider = create_openai_provider(provider_name, opts)
    api = ProviderApi.list_for_provider(provider.id) |> Enum.find(&(&1.api_surface == :openai))

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: model_id,
        source: :manual
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    provider
  end

  defp create_openai_provider(provider_name, opts) do
    credential_name = "#{provider_name}-cred"
    {:ok, _} = Credentials.store(credential_name, "live-secret", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: provider_name,
        credential: credential_name,
        preset_key: Keyword.get(opts, :preset_key)
      })

    {:ok, _api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: Keyword.get(opts, :base_url, "https://api.openai.com/v1")
      })

    provider
  end
end
