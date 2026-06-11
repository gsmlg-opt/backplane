defmodule Backplane.Services.WebXSearchTest do
  use Backplane.DataCase, async: false

  alias Backplane.Services.Web
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  setup do
    previous = Application.get_env(:backplane, :web_x_search_req_options)

    Application.put_env(:backplane, :web_x_search_req_options,
      plug: {Req.Test, Backplane.Services.WebXSearch}
    )

    Settings.set("services.web.enabled", true)
    Settings.set("services.web_x_search.credential", nil)
    Settings.set("services.web_x_search.model", nil)

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :web_x_search_req_options, previous)
      else
        Application.delete_env(:backplane, :web_x_search_req_options)
      end
    end)

    :ok
  end

  test "web service exposes web::x_search with ManagedService-shaped fields" do
    tool = x_search_tool()

    assert tool.name == "web::x_search"
    assert is_binary(tool.description)
    assert is_map(tool.input_schema)
    assert is_function(tool.handler, 1)
    assert Map.keys(tool.input_schema["properties"]) == ["query"]
    assert get_in(tool.input_schema, ["properties", "query", "type"]) == "string"
    assert get_in(tool.input_schema, ["properties", "query", "description"]) == "Search text"
    assert tool.input_schema["required"] == ["query"]
    assert tool.input_schema["additionalProperties"] == false
  end

  test "web::x_search calls xAI Responses API with configured API key credential" do
    {:ok, _} = Credentials.store("xai-api-key", "xai-secret", "service")
    Settings.set("services.web_x_search.credential", "xai-api-key")

    Req.Test.stub(Backplane.Services.WebXSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/v1/responses"
      assert {"authorization", "Bearer xai-secret"} in conn.req_headers

      decoded = Jason.decode!(body)
      assert decoded["model"] == "grok-4.3"

      assert decoded["input"] == [
               %{"role" => "user", "content" => "what are people saying about elixir?"}
             ]

      assert decoded["tools"] == [%{"type" => "x_search"}]

      Req.Test.json(conn, %{
        "id" => "resp_1",
        "model" => "grok-4.3",
        "output" => [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [
              %{
                "type" => "output_text",
                "text" => "Elixir discussion is active.",
                "annotations" => [
                  %{
                    "type" => "url_citation",
                    "url" => "https://x.com/elixirlang/status/1",
                    "title" => "Elixir"
                  }
                ]
              }
            ]
          }
        ],
        "citations" => ["https://x.com/elixirlang/status/2"],
        "usage" => %{"num_server_side_tools_used" => 1}
      })
    end)

    assert {:ok, result} =
             x_search_tool().handler.(%{
               "query" => "what are people saying about elixir?"
             })

    assert Map.keys(result) |> Enum.sort() == ["citations", "query", "result"]
    assert result["query"] == "what are people saying about elixir?"
    assert result["result"] == "Elixir discussion is active."
    assert "https://x.com/elixirlang/status/1" in result["citations"]
    assert "https://x.com/elixirlang/status/2" in result["citations"]
  end

  test "web::x_search uses configured xAI OAuth credential when no credential argument is provided" do
    future_ms = System.system_time(:millisecond) + 60 * 60 * 1000

    {:ok, _} =
      Credentials.store_device_token(
        "xai-grok",
        "xai_oauth",
        %{
          "type" => "xai_grok_oauth",
          "auth_mode" => "grok",
          "access_token" => "xai-oauth-access",
          "refresh_token" => "xai-refresh",
          "expires_at" => future_ms
        },
        %{"auth_mode" => "grok"}
      )

    Settings.set("services.web_x_search.credential", "xai-grok")

    Req.Test.stub(Backplane.Services.WebXSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/v1/responses"
      assert {"authorization", "Bearer xai-oauth-access"} in conn.req_headers

      decoded = Jason.decode!(body)
      assert decoded["tools"] == [%{"type" => "x_search"}]

      Req.Test.json(conn, %{
        "id" => "resp_oauth",
        "model" => "grok-4.3",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "OAuth-backed X result."}]
          }
        ],
        "usage" => %{}
      })
    end)

    assert {:ok, result} =
             x_search_tool().handler.(%{
               "query" => "latest from xai"
             })

    assert result["result"] == "OAuth-backed X result."
  end

  defp x_search_tool do
    Enum.find(Web.tools(), &(&1.name == "web::x_search")) ||
      flunk("expected web::x_search to be registered")
  end
end
