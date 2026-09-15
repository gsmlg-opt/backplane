defmodule Backplane.Test.TestLLMUpstream do
  @moduledoc """
  Plug.Router that simulates Anthropic and OpenAI LLM API endpoints
  for integration testing of the LLM proxy.

  ## Endpoints

    * `POST /v1/messages` — Anthropic Messages API (streaming and non-streaming)
    * `POST /v1/chat/completions` — OpenAI Chat Completions API (streaming and non-streaming)
    * `GET /v1/models` — OpenAI Models list (returns empty list)
    * `GET /test/last-auth` — Returns the last auth headers received (for test verification)

  ## Error Simulation

  If the request body `model` equals `"error-model"`, the endpoint returns 500.
  """

  use Plug.Router

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    body_reader: {Backplane.Transport.CacheBodyReader, :read_body, []}

  plug :match
  plug :dispatch

  # ── Agent for storing last-seen auth headers ──

  @agent __MODULE__.AuthStore

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: @agent)
  end

  defp store_auth(conn) do
    capture = %{
      headers: conn.req_headers,
      path: conn.request_path,
      body: conn.body_params,
      raw_body: conn.assigns[:raw_body]
    }

    if Process.whereis(@agent) do
      Agent.update(@agent, fn previous ->
        Map.put(capture, :submissions, Map.get(previous, :submissions, 0) + 1)
      end)
    end

    conn
  end

  defp last_auth do
    if Process.whereis(@agent) do
      Agent.get(@agent, & &1)
    else
      %{}
    end
  end

  # ── Routes ──

  get "/v1/models" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"object" => "list", "data" => []}))
  end

  get "/test/last-auth" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(last_auth()))
  end

  post "/v1/messages" do
    conn = store_auth(conn)
    model = conn.body_params["model"] || "unknown"

    if model == "error-model" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(500, Jason.encode!(%{"error" => %{"message" => "Internal server error"}}))
    else
      if conn.body_params["stream"] == true do
        anthropic_stream(conn, model)
      else
        anthropic_non_stream(conn, model)
      end
    end
  end

  post "/v1/chat/completions" do
    conn = store_auth(conn)
    model = conn.body_params["model"] || "unknown"

    if model == "error-model" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(500, Jason.encode!(%{"error" => %{"message" => "Internal server error"}}))
    else
      if conn.body_params["stream"] == true do
        openai_stream(conn, model)
      else
        openai_non_stream(conn, model)
      end
    end
  end

  post "/v1/responses" do
    conn = store_auth(conn)
    model = conn.body_params["model"] || "unknown"

    cond do
      model == "responses-error" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "error" => %{"type" => "invalid_request_error", "code" => "bad_fixture"}
          })
        )

      conn.body_params["stream"] == true ->
        responses_stream(conn, model)

      true ->
        responses_non_stream(conn, model)
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  # ── Anthropic helpers ──

  defp anthropic_non_stream(conn, model) do
    body = %{
      "id" => "msg_test_123",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => "Hello from test upstream"}],
      "model" => model,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp anthropic_stream(conn, model) do
    events = [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_test_123",
          "type" => "message",
          "role" => "assistant",
          "model" => model,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Hello"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => " from test"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 5}
      },
      %{"type" => "message_stop"}
    ]

    send_sse(conn, events)
  end

  # ── OpenAI helpers ──

  defp openai_non_stream(conn, model) do
    body = %{
      "id" => "chatcmpl-test123",
      "object" => "chat.completion",
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => "Hello from test upstream"},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp openai_stream(conn, model) do
    chunks = [
      %{
        "id" => "chatcmpl-test123",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "content" => ""},
            "finish_reason" => nil
          }
        ]
      },
      %{
        "id" => "chatcmpl-test123",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "Hello"}, "finish_reason" => nil}
        ]
      },
      %{
        "id" => "chatcmpl-test123",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => " from test"}, "finish_reason" => nil}
        ]
      },
      %{
        "id" => "chatcmpl-test123",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [
          %{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }
    ]

    events = Enum.map(chunks, &Jason.encode!/1) ++ ["[DONE]"]
    send_sse(conn, events, :raw)
  end

  defp responses_non_stream(conn, model) do
    if conn.body_params["input"] == "malformed-nested" do
      body =
        ~S({"id":"resp_malformed","status":"completed","output":[{"type":"function_call","id":"fc_bad","name":"lookup","arguments":null}],"usage":{"input_tokens":2,"output_tokens":1,"input_tokens_details":1}})

      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    else
      body = %{
        "id" => "resp_host_1",
        "object" => "response",
        "status" => "completed",
        "model" => model,
        "output" => [
          %{
            "type" => "function_call",
            "id" => "fc_1",
            "call_id" => "call_1",
            "name" => "lookup",
            "arguments" => ~S({"q":"fixture"}),
            "status" => "completed"
          }
        ],
        "usage" => %{
          "input_tokens" => 13,
          "input_tokens_details" => %{"cached_tokens" => 4},
          "output_tokens" => 8,
          "output_tokens_details" => %{"reasoning_tokens" => 2},
          "total_tokens" => 21
        }
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  defp responses_stream(conn, model) do
    if conn.body_params["input"] == "malformed-nested" do
      malformed_responses_stream(conn)
    else
      regular_responses_stream(conn, model)
    end
  end

  defp regular_responses_stream(conn, model) do
    events = [
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "id" => "fc_stream",
          "call_id" => "call_stream",
          "name" => "lookup",
          "arguments" => ~S({"q":"stream"}),
          "status" => "completed"
        }
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_host_stream",
          "status" => "completed",
          "model" => model,
          "usage" => %{
            "input_tokens" => 9,
            "input_tokens_details" => %{"cached_tokens" => 1},
            "output_tokens" => 6,
            "output_tokens_details" => %{"reasoning_tokens" => 2},
            "total_tokens" => 15
          }
        }
      }
    ]

    send_sse(conn, events)
  end

  defp malformed_responses_stream(conn) do
    chunks = [
      ~S(data: {"type":"response.created","response":1}) <> "\n\n",
      ~S(data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_bad","name":"lookup","arguments":{"q":"bad"},"status":"completed"}}) <>
        "\n\n",
      ~S(data: {"type":"response.completed","response":{"id":"resp_malformed_stream","status":"completed","usage":{"input_tokens":2,"output_tokens":1}}}) <>
        "\n\n"
    ]

    conn = conn |> put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  # ── SSE transport ──

  defp send_sse(conn, events) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(events, conn, fn event, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Jason.encode!(event)}\n\n")
      conn
    end)
  end

  defp send_sse(conn, events, :raw) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(events, conn, fn event, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, "data: #{event}\n\n")
      conn
    end)
  end
end
