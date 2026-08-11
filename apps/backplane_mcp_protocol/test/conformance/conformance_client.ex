defmodule Conformance.Client do
  @moduledoc false

  alias Backplane.McpProtocol.Client, as: ProtocolClient
  alias Backplane.McpProtocol.Client.Authorization
  alias Backplane.McpProtocol.Client.Authorization.CredentialStore
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Response

  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @client_info_key "io.modelcontextprotocol/clientInfo"

  @client_info %{"name" => "backplane-mcp-conformance", "version" => "1.0.0"}
  @client_capabilities %{
    "roots" => %{},
    "sampling" => %{},
    "elicitation" => %{"form" => %{}}
  }
  @callback_uri "http://localhost:3000/callback"
  @cimd_client_id "https://conformance-test.local/client-metadata.json"
  @credential_store [store: [adapter: Conformance.Client.CredentialStoreAdapter]]
  @token_auth_methods ~w(client_secret_basic client_secret_post none)

  @spec run(String.t(), String.t(), map(), String.t()) :: :ok | {:error, term()}
  def run(url, scenario, context, protocol_version)
      when is_binary(url) and is_binary(scenario) and is_map(context) and is_binary(protocol_version) do
    case scenario do
      "tools_call" -> run_tools_call(url, protocol_version)
      "request-metadata" -> run_request_metadata(url, protocol_version)
      "sep-2322-client-request-state" -> run_mrtr(url, protocol_version)
      "http-standard-headers" -> run_standard_headers(url, protocol_version)
      "http-custom-headers" -> run_custom_headers(url, context, protocol_version)
      "http-invalid-tool-headers" -> run_invalid_tool_headers(url, protocol_version)
      "json-schema-ref-no-deref" -> run_schema_ref(url, protocol_version)
      "auth/" <> _auth_scenario -> run_oauth(url, scenario, context, protocol_version)
      _unknown -> {:error, {:unsupported_conformance_scenario, scenario}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_tools_call(url, protocol_version) do
    with_client(url, protocol_version, fn client ->
      with {:ok, %Response{}} <- ProtocolClient.list_tools(client),
           {:ok, %Response{}} <- ProtocolClient.call_tool(client, "add_numbers", %{"a" => 2, "b" => 3}) do
        :ok
      end
    end)
  end

  defp run_schema_ref(url, protocol_version) do
    with_client(url, protocol_version, fn client ->
      case ProtocolClient.list_tools(client) do
        {:ok, %Response{}} -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end
    end)
  end

  defp run_standard_headers(url, protocol_version) do
    with_client(url, protocol_version, fn client ->
      with {:ok, %Response{result: %{"tools" => tools}}} <- ProtocolClient.list_tools(client),
           :ok <- call_first_tool(client, tools),
           {:ok, %Response{result: %{"resources" => resources}}} <- ProtocolClient.list_resources(client),
           :ok <- read_first_resource(client, resources),
           {:ok, %Response{result: %{"prompts" => prompts}}} <- ProtocolClient.list_prompts(client) do
        get_first_prompt(client, prompts)
      end
    end)
  end

  defp run_custom_headers(url, context, protocol_version) do
    with_client(url, protocol_version, fn client ->
      with {:ok, %Response{}} <- ProtocolClient.list_tools(client) do
        context
        |> Map.get("toolCalls", [])
        |> Enum.reduce_while(:ok, fn call, :ok ->
          case ProtocolClient.call_tool(client, call["name"], call["arguments"] || %{}) do
            {:ok, %Response{}} -> {:cont, :ok}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
        end)
      end
    end)
  end

  defp run_invalid_tool_headers(url, protocol_version) do
    with_client(url, protocol_version, fn client ->
      with {:ok, %Response{result: %{"tools" => tools}}} <- ProtocolClient.list_tools(client),
           ["valid_tool"] <- Enum.map(tools, & &1["name"]),
           {:ok, %Response{}} <-
             ProtocolClient.call_tool(client, "valid_tool", %{"region" => "us-west1"}) do
        :ok
      else
        names when is_list(names) -> {:error, {:invalid_tools_retained, names}}
        other -> other
      end
    end)
  end

  defp run_request_metadata(url, _protocol_version) do
    with_client(url, :auto, fn _client -> :ok end)
  end

  defp run_mrtr(url, protocol_version) do
    parent = self()

    with_client(url, protocol_version, fn client ->
      :ok =
        ProtocolClient.register_elicitation_callback(client, fn _message, _schema ->
          ref = make_ref()
          send(parent, {:mrtr_elicitation, self(), ref})

          receive do
            {:resolve_mrtr_elicitation, ^ref} -> {:accept, %{"confirmed" => true}}
          after
            5_000 -> {:error, "MRTR conformance elicitation timed out"}
          end
        end)

      with {:ok, %Response{}} <- ProtocolClient.list_tools(client),
           {:ok, %Response{}} <-
             resolve_mrtr_call(client, "test_mrtr_echo_state", fn ->
               case ProtocolClient.call_tool(client, "test_mrtr_unrelated", %{}) do
                 {:ok, %Response{}} -> :ok
                 other -> other
               end
             end),
           {:ok, %Response{}} <- resolve_mrtr_call(client, "test_mrtr_no_state"),
           {:ok, %Response{}} <- ProtocolClient.call_tool(client, "test_mrtr_no_result_type", %{}) do
        :ok
      end
    end)
  end

  defp resolve_mrtr_call(client, tool_name, before_resolution \\ fn -> :ok end) do
    pending = Task.async(fn -> ProtocolClient.call_tool(client, tool_name, %{}, timeout: 10_000) end)

    receive do
      {:mrtr_elicitation, resolver, ref} ->
        case before_resolution.() do
          :ok ->
            send(resolver, {:resolve_mrtr_elicitation, ref})
            Task.await(pending, 10_000)

          error ->
            send(resolver, {:resolve_mrtr_elicitation, ref})
            Task.shutdown(pending, :brutal_kill)
            error
        end
    after
      5_000 ->
        Task.shutdown(pending, :brutal_kill)
        {:error, :mrtr_elicitation_not_received}
    end
  end

  defp post_rpc(url, method, params, protocol_version, extra_headers) do
    id = next_id()
    params = Map.put_new(params, "_meta", request_meta(protocol_version))
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    headers =
      %{
        "content-type" => "application/json",
        "accept" => "application/json, text/event-stream",
        "mcp-protocol-version" => protocol_version,
        "mcp-method" => method
      }
      |> maybe_put_name_header(params)
      |> Map.merge(extra_headers)

    case http_request(:post, url, headers, body) do
      {:ok, response} ->
        {:ok,
         %{
           status: response.status,
           headers: response.headers,
           message: decode_rpc_body(response.body, response.headers)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_meta(protocol_version) do
    %{
      @protocol_version_key => protocol_version,
      @client_capabilities_key => @client_capabilities,
      @client_info_key => @client_info
    }
  end

  defp maybe_put_name_header(headers, %{"name" => name}) when is_binary(name), do: Map.put(headers, "mcp-name", name)

  defp maybe_put_name_header(headers, %{"uri" => uri}) when is_binary(uri), do: Map.put(headers, "mcp-name", uri)

  defp maybe_put_name_header(headers, _params), do: headers

  defp decode_rpc_body(body, headers) do
    if content_type(headers) == "text/event-stream" do
      body
      |> Backplane.McpProtocol.SSE.Parser.run()
      |> Enum.find_value(fn
        %Backplane.McpProtocol.SSE.Event{data: data} ->
          case JSON.decode(data) do
            {:ok, message} -> message
            _invalid -> nil
          end

        _other ->
          nil
      end)
    else
      case JSON.decode(body) do
        {:ok, message} -> message
        {:error, _reason} -> nil
      end
    end
  end

  defp content_type(headers) do
    headers
    |> header_value("content-type")
    |> case do
      nil -> nil
      value -> value |> String.split(";", parts: 2) |> hd() |> String.downcase()
    end
  end

  defp header_value(headers, wanted) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == wanted, do: value
    end)
  end

  defp header_values(headers, wanted) do
    for {name, value} <- headers, String.downcase(name) == wanted, do: value
  end

  defp http_request(method, url, headers, body) do
    method
    |> Finch.build(url, Map.to_list(headers), body)
    |> Finch.request(Backplane.McpProtocol.Finch, receive_timeout: 10_000)
  end

  defp with_client(url, protocol_version, callback) do
    unique = System.unique_integer([:positive, :monotonic])
    client = {:global, {__MODULE__, :client, unique}}
    transport = {:global, {__MODULE__, :transport, unique}}
    {base_url, mcp_path} = split_url(url)

    opts = [
      name: client,
      transport_name: transport,
      transport: {:streamable_http, base_url: base_url, mcp_path: mcp_path},
      client_info: @client_info,
      capabilities: @client_capabilities,
      protocol_version: protocol_version,
      timeout: 10_000
    ]

    case ProtocolClient.start_link(opts) do
      {:ok, supervisor} ->
        try do
          with :ok <- ProtocolClient.await_ready(client, timeout: 10_000) do
            callback.(client)
          end
        after
          Supervisor.stop(supervisor, :normal, 5_000)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_url(url) do
    uri = URI.parse(url)
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    base = URI.to_string(%{uri | path: nil, query: nil, fragment: nil})
    {base, path}
  end

  defp call_first_tool(_client, []), do: {:error, :standard_headers_tool_missing}

  defp call_first_tool(client, [%{"name" => name} | _tools]) do
    args = if name == "add_numbers", do: %{"a" => 2, "b" => 3}, else: %{}

    case ProtocolClient.call_tool(client, name, args) do
      {:ok, %Response{}} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp read_first_resource(_client, []), do: {:error, :standard_headers_resource_missing}

  defp read_first_resource(client, [%{"uri" => uri} | _resources]) do
    case ProtocolClient.read_resource(client, uri) do
      {:ok, %Response{}} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp get_first_prompt(_client, []), do: {:error, :standard_headers_prompt_missing}

  defp get_first_prompt(client, [%{"name" => name} = prompt | _prompts]) do
    arguments = Map.get(prompt, "arguments", [])
    values = Map.new(arguments || [], fn argument -> {argument["name"], "conformance"} end)

    case ProtocolClient.get_prompt(client, name, values) do
      {:ok, %Response{}} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp next_id do
    current = Process.get({__MODULE__, :next_id}, 0) + 1
    Process.put({__MODULE__, :next_id}, current)
    current
  end

  defp run_oauth(url, scenario, context, protocol_version) do
    with {:ok, auth, _tools} <-
           authorized_request(url, "tools/list", %{}, protocol_version, scenario, context, nil, 0),
         {:ok, _auth, _call} <-
           authorized_request(
             url,
             "tools/call",
             %{"name" => "test-tool", "arguments" => %{}},
             protocol_version,
             scenario,
             context,
             auth,
             0
           ) do
      :ok
    end
  end

  defp authorized_request(url, method, params, protocol_version, scenario, context, auth, authorization_attempts) do
    case post_rpc(url, method, params, protocol_version, bearer_headers(auth)) do
      {:ok, %{status: status, message: %{"result" => result}}} when status in 200..299 ->
        {:ok, auth, result}

      {:ok, %{status: status, headers: response_headers}}
      when status in [401, 403] and authorization_attempts < 3 ->
        with {:ok, next_auth} <- authorize(url, response_headers, scenario, context, auth) do
          authorized_request(
            url,
            method,
            params,
            protocol_version,
            scenario,
            context,
            next_auth,
            authorization_attempts + 1
          )
        end

      {:ok, response} ->
        {:error, {:oauth_mcp_request_failed, method, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize(resource_url, response_headers, scenario, context, previous) do
    with {:ok, challenge} <- bearer_challenge(response_headers),
         {:ok, prm} <- discover_protected_resource(resource_url, challenge),
         {:ok, resource} <- validate_protected_resource(resource_url, prm),
         {:ok, issuer} <- authorization_server(prm),
         {:ok, metadata} <- discover_authorization_server(issuer),
         :ok <- validate_metadata_issuer(issuer, metadata),
         {:ok, registration} <- registration(issuer, metadata, scenario, context, previous),
         scopes = select_scopes(challenge, prm, metadata, previous),
         {:ok, code, verifier} <- authorization_code(metadata, issuer, registration, resource, scopes),
         {:ok, token} <- exchange_code(metadata, registration, resource, scopes, code, verifier) do
      {:ok,
       Map.merge(registration, %{
         access_token: token["access_token"],
         token_type: token["token_type"],
         issuer: issuer,
         scopes: token_scopes(token, scopes)
       })}
    end
  end

  defp bearer_headers(nil), do: %{}

  defp bearer_headers(%{access_token: token, token_type: token_type}) do
    %{"authorization" => "#{token_type} #{token}"}
  end

  defp bearer_challenge(headers) do
    headers
    |> header_values("www-authenticate")
    |> Enum.find_value(&parse_bearer_challenge/1)
    |> case do
      nil -> {:error, :bearer_challenge_missing}
      challenge -> {:ok, challenge}
    end
  end

  defp parse_bearer_challenge(value) do
    case Regex.run(~r/(?:^|,\s*)Bearer(?:\s+|$)/i, value, return: :index) do
      [{start, length}] ->
        value
        |> binary_part(start + length, byte_size(value) - start - length)
        |> then(fn params ->
          ~r/([A-Za-z_][A-Za-z0-9_-]*)="([^"]*)"/
          |> Regex.scan(params)
          |> Map.new(fn [_whole, key, val] -> {String.downcase(key), val} end)
        end)

      nil ->
        nil
    end
  end

  defp discover_protected_resource(_resource_url, %{"resource_metadata" => url}), do: fetch_json(url)

  defp discover_protected_resource(resource_url, _challenge) do
    uri = URI.parse(resource_url)
    origin = uri_origin(uri)
    path = if uri.path in [nil, "", "/"], do: "", else: uri.path

    fetch_first_json([
      origin <> "/.well-known/oauth-protected-resource" <> path,
      origin <> "/.well-known/oauth-protected-resource"
    ])
  end

  defp validate_protected_resource(resource_url, %{"resource" => resource}) when is_binary(resource) do
    requested = URI.parse(resource_url)
    advertised = URI.parse(resource)
    advertised_path = advertised.path || "/"
    requested_path = requested.path || "/"

    same_authority? =
      requested.scheme == advertised.scheme and requested.host == advertised.host and
        effective_port(requested) == effective_port(advertised)

    path_matches? =
      advertised_path == requested_path or
        advertised_path == "/" or
        (String.ends_with?(advertised_path, "/") and
           String.starts_with?(requested_path, advertised_path))

    if same_authority? and path_matches? and is_nil(advertised.fragment) do
      {:ok, resource}
    else
      {:error, {:protected_resource_mismatch, resource_url, resource}}
    end
  end

  defp validate_protected_resource(_resource_url, prm), do: {:error, {:invalid_protected_resource_metadata, prm}}

  defp authorization_server(%{"authorization_servers" => [issuer | _]}) when is_binary(issuer), do: {:ok, issuer}

  defp authorization_server(prm), do: {:error, {:authorization_server_missing, prm}}

  defp discover_authorization_server(issuer) do
    uri = URI.parse(issuer)
    origin = uri_origin(uri)
    issuer_path = if uri.path in [nil, "", "/"], do: "", else: uri.path

    fetch_first_json([
      origin <> "/.well-known/oauth-authorization-server" <> issuer_path,
      origin <> issuer_path <> "/.well-known/openid-configuration"
    ])
  end

  defp validate_metadata_issuer(issuer, %{"issuer" => returned}), do: Authorization.validate_issuer(issuer, returned)

  defp validate_metadata_issuer(_issuer, metadata), do: {:error, {:authorization_server_issuer_missing, metadata}}

  defp registration(issuer, _metadata, _scenario, _context, %{issuer: issuer} = previous) do
    case CredentialStore.fetch(issuer, previous.client_id, @credential_store) do
      {:ok, credentials} -> {:ok, atomize_registration(credentials)}
      {:error, reason} -> {:error, {:credential_fetch_failed, reason}}
    end
  end

  defp registration(issuer, metadata, scenario, context, _previous) do
    pre_registered =
      if is_binary(context["client_id"]) do
        %{
          "client_id" => context["client_id"],
          "client_secret" => context["client_secret"],
          "token_endpoint_auth_method" => "client_secret_basic"
        }
      end

    cimd = if scenario == "auth/basic-cimd", do: @cimd_client_id

    with {:ok, selection} <-
           Authorization.select_registration(metadata,
             pre_registered: pre_registered,
             client_id_metadata_document: cimd,
             dynamic_client_registration: true
           ),
         {:ok, credentials} <- perform_registration(selection, metadata),
         :ok <-
           CredentialStore.put(
             issuer,
             credentials["client_id"],
             credentials,
             @credential_store
           ),
         {:ok, stored} <-
           CredentialStore.fetch(issuer, credentials["client_id"], @credential_store) do
      {:ok, atomize_registration(stored)}
    end
  end

  defp perform_registration({:pre_registered, credentials}, _metadata), do: {:ok, credentials}

  defp perform_registration({:client_id_metadata_document, client_id}, metadata) do
    with {:ok, auth_method} <- preferred_token_auth_method(metadata) do
      {:ok,
       %{
         "client_id" => client_id,
         "token_endpoint_auth_method" => auth_method
       }}
    end
  end

  defp perform_registration({:dynamic_client_registration, endpoint}, metadata) do
    with {:ok, auth_method} <- preferred_token_auth_method(metadata),
         body =
           Authorization.registration_metadata(
             %{
               "client_name" => "Backplane MCP conformance client",
               "redirect_uris" => [@callback_uri],
               "grant_types" => ["authorization_code", "refresh_token"],
               "response_types" => ["code"],
               "token_endpoint_auth_method" => auth_method
             },
             :native
           ),
         {:ok, response} <- post_json(endpoint, body),
         true <- response.status == 201,
         {:ok, registration} <- JSON.decode(response.body),
         client_id when is_binary(client_id) <- registration["client_id"],
         returned_method = registration["token_endpoint_auth_method"] || auth_method,
         true <- returned_method in @token_auth_methods do
      {:ok, Map.put(registration, "token_endpoint_auth_method", returned_method)}
    else
      other -> {:error, {:dynamic_registration_failed, other}}
    end
  end

  defp preferred_token_auth_method(metadata) do
    supported = Map.get(metadata, "token_endpoint_auth_methods_supported", ["client_secret_basic"])

    case Enum.find(supported, &(&1 in @token_auth_methods)) do
      nil -> {:error, {:unsupported_token_endpoint_auth_methods, supported}}
      method -> {:ok, method}
    end
  end

  defp atomize_registration(credentials) do
    %{
      client_id: credentials["client_id"],
      client_secret: credentials["client_secret"],
      token_endpoint_auth_method: credentials["token_endpoint_auth_method"] || "client_secret_basic"
    }
  end

  defp select_scopes(challenge, prm, metadata, previous) do
    prior = if previous, do: previous.scopes, else: []

    selected =
      case challenge["scope"] do
        scope when is_binary(scope) and scope != "" -> prior ++ String.split(scope)
        _missing -> prior ++ Map.get(prm, "scopes_supported", [])
      end

    if "offline_access" in Map.get(metadata, "scopes_supported", []) do
      Enum.uniq(selected ++ ["offline_access"])
    else
      Enum.uniq(selected)
    end
  end

  defp authorization_code(metadata, issuer, registration, resource, scopes) do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    query =
      maybe_put_scope(
        %{
          "response_type" => "code",
          "client_id" => registration.client_id,
          "redirect_uri" => @callback_uri,
          "state" => state,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "resource" => resource
        },
        scopes
      )

    url = merge_url_query(metadata["authorization_endpoint"], query)

    with {:ok, response} <- http_request(:get, url, %{"accept" => "text/html"}, nil),
         true <- response.status in [301, 302, 303, 307, 308],
         location when is_binary(location) <- header_value(response.headers, "location"),
         callback = URI.parse(location),
         true <- valid_callback_uri?(callback),
         params = URI.decode_query(callback.query || ""),
         ^state <- params["state"],
         :ok <- Authorization.validate_issuer(issuer, params["iss"], metadata),
         code when is_binary(code) <- params["code"] do
      {:ok, code, verifier}
    else
      other -> {:error, {:authorization_response_failed, other}}
    end
  end

  defp exchange_code(metadata, registration, resource, scopes, code, verifier) do
    form =
      maybe_put_scope(
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => @callback_uri,
          "code_verifier" => verifier,
          "client_id" => registration.client_id,
          "resource" => resource
        },
        scopes
      )

    with {:ok, {headers, form}} <- token_authentication(registration, form),
         {:ok, response} <-
           http_request(:post, metadata["token_endpoint"], headers, URI.encode_query(form)),
         true <- response.status in 200..299,
         {:ok, token} <- JSON.decode(response.body),
         access_token when is_binary(access_token) <- token["access_token"],
         token_type when is_binary(token_type) and token_type != "" <- token["token_type"] do
      {:ok, token}
    else
      other -> {:error, {:token_exchange_failed, other}}
    end
  end

  defp token_authentication(%{token_endpoint_auth_method: "client_secret_basic"} = registration, form) do
    client_id = URI.encode_www_form(registration.client_id)
    client_secret = URI.encode_www_form(registration.client_secret)
    credentials = Base.encode64("#{client_id}:#{client_secret}")

    {:ok,
     {%{
        "accept" => "application/json",
        "content-type" => "application/x-www-form-urlencoded",
        "authorization" => "Basic #{credentials}"
      }, form}}
  end

  defp token_authentication(%{token_endpoint_auth_method: "client_secret_post"} = registration, form) do
    {:ok,
     {%{
        "accept" => "application/json",
        "content-type" => "application/x-www-form-urlencoded"
      }, Map.put(form, "client_secret", registration.client_secret)}}
  end

  defp token_authentication(%{token_endpoint_auth_method: "none"}, form) do
    {:ok,
     {%{
        "accept" => "application/json",
        "content-type" => "application/x-www-form-urlencoded"
      }, form}}
  end

  defp token_authentication(registration, _form),
    do: {:error, {:unsupported_token_endpoint_auth_method, registration.token_endpoint_auth_method}}

  defp token_scopes(%{"scope" => scope}, _requested) when is_binary(scope), do: String.split(scope)
  defp token_scopes(_token, requested), do: requested

  defp merge_url_query(url, params) do
    uri = URI.parse(url)
    existing = URI.decode_query(uri.query || "")
    URI.to_string(%{uri | query: existing |> Map.merge(params) |> URI.encode_query()})
  end

  defp maybe_put_scope(params, []), do: params
  defp maybe_put_scope(params, scopes), do: Map.put(params, "scope", Enum.join(scopes, " "))

  defp valid_callback_uri?(callback) do
    registered = URI.parse(@callback_uri)

    callback.scheme == registered.scheme and
      callback.host == registered.host and
      effective_port(callback) == effective_port(registered) and
      callback.path == registered.path and is_nil(callback.userinfo) and
      is_nil(callback.fragment)
  end

  defp fetch_first_json(urls) do
    Enum.reduce_while(urls, {:error, :metadata_not_found}, fn url, _last_error ->
      case fetch_json(url) do
        {:ok, metadata} -> {:halt, {:ok, metadata}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp fetch_json(url) do
    with {:ok, response} <-
           http_request(:get, url, %{"accept" => "application/json"}, nil),
         true <- response.status in 200..299,
         {:ok, body} <- JSON.decode(response.body) do
      {:ok, body}
    else
      other -> {:error, {:metadata_request_failed, url, other}}
    end
  end

  defp post_json(url, body) do
    http_request(
      :post,
      url,
      %{"accept" => "application/json", "content-type" => "application/json"},
      JSON.encode!(body)
    )
  end

  defp uri_origin(uri) do
    URI.to_string(%{uri | path: nil, query: nil, fragment: nil})
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80
  defp effective_port(_uri), do: nil
end

defmodule Conformance.Client.CredentialStoreAdapter do
  @moduledoc false

  @behaviour Backplane.McpProtocol.Client.Authorization.CredentialStore

  @impl true
  def fetch(key, _opts) do
    case Process.get({__MODULE__, key}) do
      nil -> {:error, :not_found}
      credentials -> {:ok, credentials}
    end
  end

  @impl true
  def put(key, credentials, _opts) do
    Process.put({__MODULE__, key}, credentials)
    :ok
  end
end
