defmodule Conformance.Server do
  @moduledoc false

  alias Backplane.McpProtocol.Server
  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  @default_ip {127, 0, 0, 1}
  @default_port 4105

  def start_link(opts \\ []) do
    ip = Keyword.get(opts, :ip, @default_ip)
    port = Keyword.get(opts, :port, @default_port)
    supervisor_name = Keyword.get(opts, :name, Conformance.Server.Supervisor)

    allowed_origins = ["http://127.0.0.1:#{port}", "http://localhost:#{port}"]

    http =
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {StreamableHTTPPlug, server: Conformance.Server.Protocol, allowed_origins: allowed_origins},
        options: [ip: ip, port: port],
        ref: Conformance.Server.HTTP
      )

    children = [
      {Conformance.Server.Protocol, transport: {:streamable_http, start: true}},
      http
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: supervisor_name)
  end

  defmodule Protocol do
    @moduledoc false

    use Server,
      name: "backplane-mcp-conformance-server",
      version: "1.0.0",
      capabilities: [
        {:tools, list_changed?: true},
        {:resources, list_changed?: true},
        {:prompts, list_changed?: true},
        :completion
      ],
      protocol_versions: ["2026-07-28"]

    alias Backplane.McpProtocol.MCP.Error
    alias Backplane.McpProtocol.Server.Component.Schema
    alias Backplane.McpProtocol.Server.Frame
    alias Backplane.McpProtocol.Server.Handlers
    alias Backplane.McpProtocol.Server.Modern.Subscriptions
    alias Backplane.McpProtocol.Server.Registry
    alias Backplane.McpProtocol.Server.Response

    @image_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
    @audio_base64 "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="
    @state_secret "backplane-mcp-conformance-mrtr-v1"

    @mrtr_tools [
      "test_input_required_result_elicitation",
      "test_input_required_result_sampling",
      "test_input_required_result_list_roots",
      "test_input_required_result_request_state",
      "test_input_required_result_multiple_inputs",
      "test_input_required_result_multi_round",
      "test_input_required_result_tampered_state",
      "test_input_required_result_capabilities"
    ]

    @tools [
      {"test_simple_text", "Tests simple text content response"},
      {"test_image_content", "Tests image content response"},
      {"test_audio_content", "Tests audio content response"},
      {"test_embedded_resource", "Tests embedded resource content response"},
      {"test_multiple_content_types", "Tests a response with several content types"},
      {"test_error_handling", "Tests tool error response handling"},
      {"test_tool_with_progress", "Tests progress notifications during tool execution"},
      {"test_missing_capability", "Tests required client capability enforcement"},
      {"test_streaming_elicitation", "Diagnostic response-stream tool"},
      {"test_logging_tool", "Diagnostic logging tool"},
      {"test_trigger_tool_change", "Triggers a tools/list_changed notification"},
      {"test_trigger_prompt_change", "Triggers a prompts/list_changed notification"},
      {"test_input_required_result_elicitation", "MRTR elicitation workflow"},
      {"test_input_required_result_sampling", "MRTR sampling workflow"},
      {"test_input_required_result_list_roots", "MRTR roots/list workflow"},
      {"test_input_required_result_request_state", "MRTR requestState workflow"},
      {"test_input_required_result_multiple_inputs", "MRTR multiple-input workflow"},
      {"test_input_required_result_multi_round", "MRTR multi-round workflow"},
      {"test_input_required_result_tampered_state", "MRTR signed-state workflow"},
      {"test_input_required_result_capabilities", "MRTR client-capability workflow"}
    ]

    @impl true
    def init_request(_context, frame), do: {:ok, register_components(frame)}

    @impl true
    def init(_client_info, frame), do: {:ok, register_components(frame)}

    @impl true
    def handle_request(%{"method" => "tools/call", "params" => %{"name" => name} = params}, frame)
        when name in @mrtr_tools do
      handle_mrtr_tool(name, params, frame)
    end

    def handle_request(
          %{"method" => "prompts/get", "params" => %{"name" => "test_input_required_result_prompt"} = params},
          frame
        ) do
      handle_mrtr_prompt(params, frame)
    end

    def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

    @impl true
    def handle_tool_call("test_simple_text", _arguments, frame) do
      reply_tool(frame, "This is a simple text response for testing.")
    end

    def handle_tool_call("test_image_content", _arguments, frame) do
      response = Response.image(Response.tool(), @image_base64, "image/png")
      {:reply, response, frame}
    end

    def handle_tool_call("test_audio_content", _arguments, frame) do
      response = Response.audio(Response.tool(), @audio_base64, "audio/wav")
      {:reply, response, frame}
    end

    def handle_tool_call("test_embedded_resource", _arguments, frame) do
      response =
        Response.embedded_resource(Response.tool(), "test://embedded-resource",
          mime_type: "text/plain",
          text: "This is an embedded resource content."
        )

      {:reply, response, frame}
    end

    def handle_tool_call("test_multiple_content_types", _arguments, frame) do
      response =
        Response.tool()
        |> Response.text("Multiple content types test:")
        |> Response.image(@image_base64, "image/png")
        |> Response.embedded_resource("test://mixed-content-resource",
          mime_type: "application/json",
          text: JSON.encode!(%{"test" => "data", "value" => 123})
        )

      {:reply, response, frame}
    end

    def handle_tool_call("test_error_handling", _arguments, frame) do
      response =
        Response.error(
          Response.tool(),
          "This tool intentionally returns an error for testing"
        )

      {:reply, response, frame}
    end

    def handle_tool_call("test_tool_with_progress", _arguments, frame) do
      progress_token = frame.context.progress_token || 0

      for progress <- [0, 50, 100] do
        Server.send_progress(progress_token, progress, total: 100)
      end

      reply_tool(frame, to_string(progress_token))
    end

    def handle_tool_call("test_missing_capability", _arguments, frame) do
      if Map.has_key?(frame.context.client_capabilities, "sampling") do
        reply_tool(frame, "Success")
      else
        error =
          Error.for_version("2026-07-28", :missing_client_capability, %{
            requiredCapabilities: %{"sampling" => %{}}
          })

        {:error, error, frame}
      end
    end

    def handle_tool_call("test_streaming_elicitation", _arguments, frame) do
      progress_token = frame.context.progress_token || "conformance-stream"
      Server.send_progress(progress_token, 50, total: 100)
      reply_tool(frame, "Streaming diagnostic completed")
    end

    def handle_tool_call("test_logging_tool", _arguments, frame) do
      reply_tool(frame, "Logging evaluated")
    end

    def handle_tool_call("test_trigger_tool_change", _arguments, frame) do
      publish("notifications/tools/list_changed")
      reply_tool(frame, "Mutation triggered")
    end

    def handle_tool_call("test_trigger_prompt_change", _arguments, frame) do
      publish("notifications/prompts/list_changed")
      reply_tool(frame, "Mutation triggered")
    end

    @impl true
    def handle_resource_read("test://static-text", frame) do
      response =
        Response.text(
          Response.resource(),
          "This is the content of the static text resource."
        )

      {:reply, response, frame}
    end

    def handle_resource_read("test://static-binary", frame) do
      response = Response.blob(Response.resource(), Base.decode64!(@image_base64))
      {:reply, response, frame}
    end

    def handle_resource_read(uri, frame) do
      case Regex.run(~r{\Atest://template/([^/]+)/data\z}, uri, capture: :all_but_first) do
        [id] ->
          content = %{"id" => id, "templateTest" => true, "data" => "Data for ID: #{id}"}
          {:reply, Response.text(Response.resource(), JSON.encode!(content)), frame}

        _no_match ->
          {:error, Error.resource(:not_found, %{uri: uri}), frame}
      end
    end

    @impl true
    def handle_prompt_get("test_simple_prompt", _arguments, frame) do
      response =
        Response.user_message(
          Response.prompt(),
          %{"type" => "text", "text" => "This is a simple prompt for testing."}
        )

      {:reply, response, frame}
    end

    def handle_prompt_get("test_prompt_with_arguments", arguments, frame) do
      arg1 = fetch_argument(arguments, "arg1")
      arg2 = fetch_argument(arguments, "arg2")

      response =
        Response.user_message(
          Response.prompt(),
          %{
            "type" => "text",
            "text" => "Prompt with arguments: arg1='#{arg1}', arg2='#{arg2}'"
          }
        )

      {:reply, response, frame}
    end

    def handle_prompt_get("test_prompt_with_embedded_resource", arguments, frame) do
      uri = fetch_argument(arguments, "resourceUri")

      response =
        Response.prompt()
        |> Response.user_message(%{
          "type" => "resource",
          "resource" => %{
            "uri" => uri,
            "mimeType" => "text/plain",
            "text" => "Embedded resource content for testing."
          }
        })
        |> Response.user_message(%{
          "type" => "text",
          "text" => "Please process the embedded resource above."
        })

      {:reply, response, frame}
    end

    def handle_prompt_get("test_prompt_with_image", _arguments, frame) do
      response =
        Response.prompt()
        |> Response.user_message(%{
          "type" => "image",
          "data" => @image_base64,
          "mimeType" => "image/png"
        })
        |> Response.user_message(%{"type" => "text", "text" => "Please analyze the image above."})

      {:reply, response, frame}
    end

    @impl true
    def handle_completion(_reference, _argument, frame) do
      response = Response.with_pagination(Response.completion(), 0, false)
      {:reply, response, frame}
    end

    defp register_components(frame) do
      empty_schema =
        Schema.raw(%{"type" => "object", "properties" => %{}, "additionalProperties" => false})

      frame =
        Enum.reduce(@tools, frame, fn {name, description}, frame ->
          Frame.register_tool(frame, name,
            description: description,
            input_schema: empty_schema
          )
        end)

      frame
      |> Frame.register_resource("test://static-text",
        name: "static-text",
        title: "Static Text Resource",
        description: "A static text resource for testing",
        mime_type: "text/plain"
      )
      |> Frame.register_resource("test://static-binary",
        name: "static-binary",
        title: "Static Binary Resource",
        description: "A static binary resource for testing",
        mime_type: "image/png"
      )
      |> Frame.register_resource_template("test://template/{id}/data",
        name: "template",
        title: "Resource Template",
        description: "A resource template with parameter substitution",
        mime_type: "application/json"
      )
      |> Frame.register_prompt("test_simple_prompt",
        title: "Simple Test Prompt",
        description: "A simple prompt without arguments"
      )
      |> Frame.register_prompt("test_prompt_with_arguments",
        title: "Prompt With Arguments",
        description: "A prompt with required arguments",
        arguments: %{"arg1" => {:required, :string}, "arg2" => {:required, :string}}
      )
      |> Frame.register_prompt("test_prompt_with_embedded_resource",
        title: "Prompt With Embedded Resource",
        description: "A prompt that includes an embedded resource",
        arguments: %{"resourceUri" => {:required, :string}}
      )
      |> Frame.register_prompt("test_prompt_with_image",
        title: "Prompt With Image",
        description: "A prompt that includes image content"
      )
      |> Frame.register_prompt("test_input_required_result_prompt",
        title: "MRTR Prompt",
        description: "A prompt that requires elicitation input"
      )
    end

    defp handle_mrtr_tool("test_input_required_result_elicitation", params, frame) do
      case elicited_value(params, "user_name", "name") do
        {:ok, name} ->
          complete_tool(frame, "Hello, #{name}!")

        :error ->
          input_required(frame, %{
            "user_name" => elicitation("What is your name?", "name", "string")
          })
      end
    end

    defp handle_mrtr_tool("test_input_required_result_sampling", params, frame) do
      case get_in(params, ["inputResponses", "capital_question"]) do
        %{"content" => %{"type" => "text", "text" => text}} when is_binary(text) ->
          complete_tool(frame, text)

        _missing ->
          input_required(frame, %{
            "capital_question" => sampling("What is the capital of France?", 100)
          })
      end
    end

    defp handle_mrtr_tool("test_input_required_result_list_roots", params, frame) do
      case get_in(params, ["inputResponses", "client_roots", "roots"]) do
        roots when is_list(roots) ->
          complete_tool(frame, "Received #{length(roots)} client root(s)")

        _missing ->
          input_required(frame, %{"client_roots" => %{"method" => "roots/list", "params" => %{}}})
      end
    end

    defp handle_mrtr_tool("test_input_required_result_request_state", params, frame) do
      state_payload = %{"flow" => "request-state"}

      if valid_state?(params["requestState"], state_payload) and
           match?({:ok, true}, elicited_value(params, "confirm", "ok")) do
        complete_tool(frame, "state-ok")
      else
        input_required(
          frame,
          %{"confirm" => elicitation("Please confirm", "ok", "boolean")},
          sign_state(state_payload)
        )
      end
    end

    defp handle_mrtr_tool("test_input_required_result_multiple_inputs", params, frame) do
      state_payload = %{"flow" => "multiple-inputs"}

      complete? =
        valid_state?(params["requestState"], state_payload) and
          match?({:ok, _}, elicited_value(params, "user_name", "name")) and
          is_map(get_in(params, ["inputResponses", "greeting"])) and
          is_list(get_in(params, ["inputResponses", "client_roots", "roots"]))

      if complete? do
        complete_tool(frame, "All requested inputs received")
      else
        input_required(
          frame,
          %{
            "user_name" => elicitation("What is your name?", "name", "string"),
            "greeting" => sampling("Generate a greeting", 50),
            "client_roots" => %{"method" => "roots/list", "params" => %{}}
          },
          sign_state(state_payload)
        )
      end
    end

    defp handle_mrtr_tool("test_input_required_result_multi_round", params, frame) do
      cond do
        valid_state?(params["requestState"], %{"flow" => "multi-round", "round" => 2}) and
            match?({:ok, _}, elicited_value(params, "step2", "color")) ->
          complete_tool(frame, "Multi-round input completed")

        valid_state?(params["requestState"], %{"flow" => "multi-round", "round" => 1}) and
            match?({:ok, _}, elicited_value(params, "step1", "name")) ->
          input_required(
            frame,
            %{"step2" => elicitation("Step 2: What is your favorite color?", "color", "string")},
            sign_state(%{"flow" => "multi-round", "round" => 2})
          )

        true ->
          input_required(
            frame,
            %{"step1" => elicitation("Step 1: What is your name?", "name", "string")},
            sign_state(%{"flow" => "multi-round", "round" => 1})
          )
      end
    end

    defp handle_mrtr_tool("test_input_required_result_tampered_state", params, frame) do
      state_payload = %{"flow" => "tampered-state"}

      case {params["inputResponses"], params["requestState"]} do
        {responses, state} when is_map(responses) and is_binary(state) ->
          if valid_state?(state, state_payload) do
            complete_tool(frame, "State integrity verified")
          else
            {:error,
             Error.protocol(:invalid_params, %{
               message: "requestState failed integrity verification"
             }), frame}
          end

        _initial ->
          input_required(
            frame,
            %{"confirm" => elicitation("Please confirm", "ok", "boolean")},
            sign_state(state_payload)
          )
      end
    end

    defp handle_mrtr_tool("test_input_required_result_capabilities", _params, frame) do
      if Map.has_key?(frame.context.client_capabilities, "sampling") do
        input_required(frame, %{
          "sample" => sampling("Provide a capability-scoped response", 32)
        })
      else
        complete_tool(frame, "No declared input capability is required")
      end
    end

    defp handle_mrtr_prompt(params, frame) do
      case elicited_value(params, "user_context", "context") do
        {:ok, context} ->
          result = %{
            "messages" => [
              %{
                "role" => "user",
                "content" => %{"type" => "text", "text" => "Prompt with context: #{context}"}
              }
            ]
          }

          {:reply, result, frame}

        :error ->
          input_required(frame, %{
            "user_context" => elicitation("What context should the prompt use?", "context", "string")
          })
      end
    end

    defp input_required(frame, requests, state \\ nil) do
      result = %{"resultType" => "input_required", "inputRequests" => requests}
      result = if state, do: Map.put(result, "requestState", state), else: result
      {:reply, result, frame}
    end

    defp complete_tool(frame, text) do
      result = Response.to_protocol(Response.text(Response.tool(), text))
      {:reply, result, frame}
    end

    defp elicitation(message, field, type) do
      %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => message,
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{field => %{"type" => type}},
            "required" => [field]
          }
        }
      }
    end

    defp sampling(message, max_tokens) do
      %{
        "method" => "sampling/createMessage",
        "params" => %{
          "messages" => [
            %{"role" => "user", "content" => %{"type" => "text", "text" => message}}
          ],
          "maxTokens" => max_tokens
        }
      }
    end

    defp elicited_value(params, request_key, field) do
      case get_in(params, ["inputResponses", request_key]) do
        %{"action" => "accept", "content" => content} when is_map(content) ->
          case Map.fetch(content, field) do
            {:ok, value} -> {:ok, value}
            :error -> :error
          end

        _invalid ->
          :error
      end
    end

    defp sign_state(payload) do
      encoded_payload = payload |> JSON.encode!() |> Base.url_encode64(padding: false)
      signature = :crypto.mac(:hmac, :sha256, @state_secret, encoded_payload)
      encoded_payload <> "." <> Base.url_encode64(signature, padding: false)
    end

    defp valid_state?(state, expected_payload) when is_binary(state) do
      with [encoded_payload, encoded_signature] <- String.split(state, ".", parts: 2),
           {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
           expected_signature = :crypto.mac(:hmac, :sha256, @state_secret, encoded_payload),
           true <- signature == expected_signature,
           {:ok, payload} <- Base.url_decode64(encoded_payload, padding: false),
           {:ok, ^expected_payload} <- JSON.decode(payload) do
        true
      else
        _invalid -> false
      end
    end

    defp valid_state?(_state, _expected_payload), do: false

    defp reply_tool(frame, text) do
      {:reply, Response.text(Response.tool(), text), frame}
    end

    defp fetch_argument(arguments, name) do
      Map.get(arguments, name) || Map.get(arguments, String.to_atom(name))
    end

    defp publish(method) do
      notification = %{"jsonrpc" => "2.0", "method" => method, "params" => %{}}
      Subscriptions.publish(Registry.subscriptions_name(__MODULE__), notification)
    end
  end
end
