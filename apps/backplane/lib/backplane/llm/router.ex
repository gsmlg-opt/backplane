defmodule Backplane.LLM.Router do
  @moduledoc """
  Plug.Router that handles LLM proxy requests.

  Aggregates LLM providers behind a single OpenAI/Anthropic-compatible endpoint.
  Routes:
  - GET  /v1/models              — aggregated model listing
  - POST /v1/messages            — Anthropic Messages API
  - POST /v1/chat/completions    — OpenAI Chat Completions API
  - POST _                       — catch-all forwarded as :openai
  """

  use Plug.Router

  require Logger

  import Plug.Conn

  alias Backplane.LLM.{CredentialPlug, ModelAlias, ModelExtractor, ModelResolver, Provider}
  alias Backplane.LLM.RouteLoader
  alias Backplane.Transport.CacheBodyReader
  alias Relayixir.Config.UpstreamConfig

  plug Backplane.Transport.CORS
  plug :match
  plug Backplane.Transport.AuthPlug

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 50_000_000,
    body_reader: {CacheBodyReader, :read_body, []}

  plug :dispatch

  # ── Routes ────────────────────────────────────────────────────────────────────

  get "/v1/models" do
    models = build_model_list()
    send_json(conn, 200, %{"object" => "list", "data" => models})
  end

  post "/v1/messages" do
    proxy_request(conn, :anthropic)
  end

  post "/v1/chat/completions" do
    proxy_request(conn, :openai)
  end

  post _ do
    proxy_request(conn, :openai)
  end

  match _ do
    send_json(conn, 404, %{
      "type" => "error",
      "error" => %{"type" => "not_found_error", "message" => "Route not found"}
    })
  end

  # ── Proxy dispatch ────────────────────────────────────────────────────────────

  defp proxy_request(conn, api_type) do
    raw_body = conn.assigns[:raw_body] || ""

    case ModelExtractor.extract(raw_body) do
      {:error, :no_model} ->
        send_model_error(conn, api_type, :no_model)

      {:error, :invalid_json} ->
        send_model_error(conn, api_type, :invalid_json)

      {:ok, model_string} ->
        case ModelResolver.resolve(api_type, model_string) do
          {:error, :no_provider} ->
            send_not_found(conn, api_type, model_string)

          {:error, :api_type_mismatch, provider} ->
            send_api_type_mismatch(conn, api_type, model_string, provider)

          {:ok, provider, raw_model} ->
            case ModelExtractor.replace_model(raw_body, raw_model) do
              {:error, :invalid_json} ->
                send_model_error(conn, api_type, :invalid_json)

              {:ok, rewritten_body} ->
                do_proxy(conn, provider, rewritten_body, api_type)
            end
        end
    end
  end

  defp do_proxy(conn, provider, rewritten_body, api_type) do
    upstream_name = RouteLoader.upstream_name(provider.id)

    case UpstreamConfig.get_upstream(upstream_name) do
      nil ->
        Logger.warning("RouteLoader: no upstream config for #{upstream_name}")
        send_error(conn, api_type, 502, "Provider upstream not configured")

      upstream_config ->
        injected_conn = CredentialPlug.inject(conn, provider)

        url = build_upstream_url(provider.api_url, conn.request_path, conn.query_string)

        headers = build_proxy_headers(injected_conn)

        proxy_with_req(conn, url, headers, rewritten_body, upstream_config)
    end
  end

  defp build_upstream_url(api_url, request_path, query_string) do
    uri = URI.parse(api_url)
    base = "#{uri.scheme}://#{uri.host}:#{effective_port(uri)}#{request_path}"

    if query_string && query_string != "" do
      "#{base}?#{query_string}"
    else
      base
    end
  end

  defp effective_port(%URI{scheme: "https", port: nil}), do: 443
  defp effective_port(%URI{scheme: "http", port: nil}), do: 80
  defp effective_port(%URI{port: port}), do: port

  defp build_proxy_headers(conn) do
    hop_by_hop = ~w(
      connection keep-alive transfer-encoding upgrade proxy-authorization
      proxy-authenticate te trailer host content-length
    )

    conn.req_headers
    |> Enum.reject(fn {name, _} -> String.downcase(name) in hop_by_hop end)
    |> Enum.map(fn {k, v} -> {k, v} end)
  end

  defp proxy_with_req(conn, url, headers, body, upstream_config) do
    timeout = Map.get(upstream_config, :request_timeout, 300_000)

    req_opts = [
      method: String.downcase(conn.method) |> String.to_existing_atom(),
      url: url,
      headers: headers,
      body: body,
      receive_timeout: timeout,
      redirect: false,
      retry: :never,
      decode_body: false
    ]

    case Req.request(req_opts) do
      {:ok, response} ->
        forward_response(conn, response)

      {:error, %{reason: reason}} ->
        Logger.warning("LLM proxy request failed: #{inspect(reason)}")
        send_error(conn, :openai, 502, "Upstream request failed: #{inspect(reason)}")
    end
  end

  defp forward_response(conn, response) do
    resp_headers =
      response.headers
      |> Enum.reject(fn {name, _} ->
        String.downcase(name) in ~w(connection keep-alive transfer-encoding)
      end)

    conn =
      Enum.reduce(resp_headers, conn, fn {name, value}, acc ->
        put_resp_header(acc, String.downcase(name), value)
      end)

    body =
      cond do
        is_binary(response.body) -> response.body
        is_list(response.body) -> IO.iodata_to_binary(response.body)
        true -> ""
      end

    send_resp(conn, response.status, body)
  end

  # ── Model listing ─────────────────────────────────────────────────────────────

  defp build_model_list do
    providers =
      Provider.list()
      |> Enum.filter(& &1.enabled)

    aliases = ModelAlias.list()

    provider_entries =
      for provider <- providers,
          model <- provider.models do
        %{
          "id" => "#{provider.name}/#{model}",
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => provider.name
        }
      end

    alias_entries =
      for model_alias <- aliases,
          provider = model_alias.provider,
          not is_nil(provider),
          not is_nil(provider.deleted_at) == true or provider.enabled do
        %{
          "id" => model_alias.alias,
          "object" => "model",
          "created" => 1_700_000_000,
          "owned_by" => provider.name
        }
      end

    provider_entries ++ alias_entries
  end

  # ── Error helpers ─────────────────────────────────────────────────────────────

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_not_found(conn, :anthropic, model) do
    send_json(conn, 404, %{
      "type" => "error",
      "error" => %{
        "type" => "not_found_error",
        "message" => "Model '#{model}' not found"
      }
    })
  end

  defp send_not_found(conn, :openai, model) do
    send_json(conn, 404, %{
      "error" => %{
        "message" => "The model '#{model}' does not exist",
        "type" => "invalid_request_error",
        "code" => "model_not_found"
      }
    })
  end

  defp send_api_type_mismatch(conn, :anthropic, model, _provider) do
    send_json(conn, 400, %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" =>
          "Model '#{model}' is not available via the Anthropic Messages API. Use /v1/chat/completions instead."
      }
    })
  end

  defp send_api_type_mismatch(conn, :openai, model, _provider) do
    send_json(conn, 400, %{
      "error" => %{
        "message" =>
          "Model '#{model}' is not available via the OpenAI Chat Completions API. Use /v1/messages instead.",
        "type" => "invalid_request_error",
        "code" => "api_type_mismatch"
      }
    })
  end

  defp send_model_error(conn, :anthropic, :no_model) do
    send_json(conn, 400, %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" => "Missing required field: model"
      }
    })
  end

  defp send_model_error(conn, :openai, :no_model) do
    send_json(conn, 400, %{
      "error" => %{
        "message" => "Missing required field: model",
        "type" => "invalid_request_error",
        "code" => "missing_required_parameter"
      }
    })
  end

  defp send_model_error(conn, :anthropic, :invalid_json) do
    send_json(conn, 400, %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" => "Invalid JSON body"
      }
    })
  end

  defp send_model_error(conn, :openai, :invalid_json) do
    send_json(conn, 400, %{
      "error" => %{
        "message" => "Invalid JSON body",
        "type" => "invalid_request_error",
        "code" => "invalid_json"
      }
    })
  end

  defp send_error(conn, :anthropic, status, message) do
    send_json(conn, status, %{
      "type" => "error",
      "error" => %{
        "type" => "api_error",
        "message" => message
      }
    })
  end

  defp send_error(conn, _api_type, status, message) do
    send_json(conn, status, %{
      "error" => %{
        "message" => message,
        "type" => "api_error",
        "code" => "proxy_error"
      }
    })
  end

  @doc false
  def call(conn, opts) do
    super(conn, opts)
  rescue
    e in Plug.Parsers.ParseError ->
      Logger.warning("LLM Router: malformed request body: #{Exception.message(e)}")

      send_resp(
        conn,
        400,
        Jason.encode!(%{
          "error" => %{
            "message" => "Malformed request body",
            "type" => "invalid_request_error",
            "code" => "invalid_json"
          }
        })
      )

    e in Plug.Parsers.RequestTooLargeError ->
      Logger.warning("LLM Router: request body too large: #{Exception.message(e)}")

      send_resp(
        conn,
        413,
        Jason.encode!(%{
          "error" => %{
            "message" => "Request body too large",
            "type" => "invalid_request_error",
            "code" => "request_too_large"
          }
        })
      )
  end
end
