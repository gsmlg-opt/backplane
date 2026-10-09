defmodule Backplane.McpProtocol.Server.Transport.StreamableHTTP.CustomSchemaValidationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.McpProtocol.Server.Registry
  alias Backplane.McpProtocol.Server.Supervisor, as: ServerSupervisor
  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  defmodule FixtureServer do
    @moduledoc false

    use Backplane.McpProtocol.Server,
      name: "custom-validation-fixture",
      version: "1.0.0",
      capabilities: [:tools],
      protocol_versions: ["2026-07-28", "2025-11-25"]

    alias Backplane.McpProtocol.Server.Component.Schema
    alias Backplane.McpProtocol.Server.Frame
    alias Backplane.McpProtocol.Server.Response

    @impl true
    def init_request(_context, frame), do: {:ok, register_tools(frame)}

    @impl true
    def init(_client_info, frame), do: {:ok, register_tools(frame)}

    @impl true
    def handle_tool_call(name, params, frame) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:tool_dispatched, name, params})
      {:reply, Response.structured(Response.tool(), params), frame}
    end

    defp register_tools(frame) do
      root_schema =
        {:custom,
         fn
           %{"name" => name} when is_binary(name) -> {:ok, %{"name" => String.trim(name)}}
           _ -> {:error, "invalid note input: name must be a string", []}
         end}

      attachment_schema = %{
        attachment:
          {:required,
           {:custom,
            Schema.validator(%{
              meta: %{name: {:required, {:string, {:transform, &String.trim/1}}}}
            })}}
      }

      extras_schema =
        {:schema, %{},
         {:additional_keys,
          {:custom,
           fn
             value when is_binary(value) -> {:ok, String.trim(value)}
             _ -> {:error, "invalid extra field: expected a string", []}
           end}}}

      strict_attachment =
        {:schema, %{name: {:required, {:string, {:transform, &String.trim/1}}}},
         {:additional_keys, {:required, {:custom, fn _ -> {:error, "unsupported attachment field", []} end}}}}

      attachments_schema = %{attachments: {:list, {:custom, Schema.validator(strict_attachment)}}}

      frame
      |> register_validator("attachments", Schema.validator(attachments_schema))
      |> register_validator("strict-root", Schema.validator(strict_attachment))
      |> register_validator(
        "direct-peri-single",
        Schema.validator(%{attachments: {:list, {:custom, fn value -> Peri.validate(root_schema, value) end}}})
      )
      |> register_validator(
        "direct-peri-list",
        Schema.validator(%{attachments: {:list, {:custom, fn value -> Peri.validate(%{name: :string}, value) end}}})
      )
      |> register_validator("root", fn params -> Peri.validate(root_schema, params) end)
      |> register_validator(
        "nested-root",
        Schema.validator(%{attachment: {:required, {:custom, Schema.validator(root_schema)}}})
      )
      |> register_validator("attachment", Schema.validator(attachment_schema))
      |> register_validator("extras", Schema.validator(extras_schema))
    end

    defp register_validator(frame, name, validator) do
      # Root Peri tuples are runtime validators, not wire JSON Schema documents.
      frame = Frame.register_tool(frame, name, input_schema: %{})
      put_in(frame.tools[name].validate_input, validator)
    end
  end

  setup do
    :persistent_term.put({FixtureServer, :test_pid}, self())
    start_supervised!({FixtureServer, transport: {:streamable_http, start: true}})
    bypass = Bypass.open()
    opts = StreamableHTTPPlug.init(server: FixtureServer)
    Bypass.stub(bypass, "POST", "/mcp", &StreamableHTTPPlug.call(&1, opts))

    on_exit(fn ->
      :persistent_term.erase({FixtureServer, :test_pid})

      for key <- [:session_config, :session_supervisor_mod, :authorization_config] do
        :persistent_term.erase({ServerSupervisor, FixtureServer, key})
      end
    end)

    %{url: "http://127.0.0.1:#{bypass.port}/mcp"}
  end

  for version <- ["2026-07-28", "2025-11-25"] do
    @version version

    test "#{version} returns a root custom validation error and accepts subsequent calls", context do
      assert_validation_survives(
        context.url,
        @version,
        "root",
        %{"name" => 1},
        "invalid note input: name must be a string",
        %{"name" => " example "},
        %{"name" => "example"}
      )
    end

    test "#{version} reports the declared path in composed attachment validation", context do
      assert_validation_survives(
        context.url,
        @version,
        "attachment",
        %{"attachment" => %{"meta" => %{"name" => 1}}},
        "attachment.meta.name: expected type of :string received 1 value",
        %{"attachment" => %{"meta" => %{"name" => " example "}}},
        %{"attachment" => %{"meta" => %{"name" => "example"}}}
      )
    end

    test "#{version} composes a root custom validator under an attachment field", context do
      assert_validation_survives(
        context.url,
        @version,
        "nested-root",
        %{"attachment" => %{"name" => 1}},
        "attachment: invalid note input: name must be a string",
        %{"attachment" => %{"name" => " example "}},
        %{"attachment" => %{"name" => "example"}}
      )
    end

    for field <- ["creator", "attachments"] do
      @field field

      test "#{version} identifies rejected root #{@field} before dispatch", context do
        assert_validation_survives(
          context.url,
          @version,
          "strict-root",
          %{"name" => "example", @field => "unsupported"},
          "#{@field}: unsupported attachment field",
          %{"name" => " example "},
          %{"name" => "example"}
        )
      end
    end

    test "#{version} normalizes direct Peri singleton callbacks before dispatch", context do
      assert_validation_survives(
        context.url,
        @version,
        "direct-peri-single",
        %{"attachments" => [%{"name" => 1}]},
        "attachments.0: invalid note input: name must be a string",
        %{"attachments" => [%{"name" => " example "}]},
        %{"attachments" => [%{"name" => "example"}]}
      )
    end

    test "#{version} normalizes direct Peri error-list callbacks before dispatch", context do
      assert_validation_survives(
        context.url,
        @version,
        "direct-peri-list",
        %{"attachments" => [%{"name" => 1}]},
        "attachments.0.name: expected type of :string received 1 value",
        %{"attachments" => [%{"name" => "example"}]},
        %{"attachments" => [%{"name" => "example"}]}
      )
    end

    test "#{version} rejects unknown attachment fields with their full list path before dispatch", context do
      assert_validation_survives(
        context.url,
        @version,
        "attachments",
        %{"attachments" => [%{"name" => "first"}, %{"name" => "second", "unknown_field" => "value"}]},
        "attachments.1.unknown_field: unsupported attachment field",
        %{"attachments" => [%{"name" => " first "}, %{"name" => " second "}]},
        %{"attachments" => [%{"name" => "first"}, %{"name" => "second"}]}
      )
    end

    test "#{version} returns useful additional-keys validation errors and preserves transformations", context do
      assert_validation_survives(
        context.url,
        @version,
        "extras",
        %{"dynamic" => 1},
        "dynamic: invalid extra field: expected a string",
        %{"dynamic" => " example "},
        %{"dynamic" => "example"}
      )
    end
  end

  defp assert_validation_survives(url, version, name, invalid, error_message, valid, expected) do
    session_id = initialize_session(url, version)
    session_supervisor = Registry.session_supervisor_name(FixtureServer)
    sessions = DynamicSupervisor.which_children(session_supervisor)

    log =
      capture_log(fn ->
        {response, body} = post(url, tool_request(version, name, invalid, 2), version, session_id)

        expected_status = if version == "2026-07-28", do: 400, else: 200
        assert response.status == expected_status
        assert body["jsonrpc"] == "2.0"
        assert body["id"] == 2
        assert body["error"]["code"] == -32_602
        assert body["error"]["data"]["message"] == error_message
        refute Map.has_key?(body, "result")
        refute_received {:tool_dispatched, _, _}

        for id <- [3, 4] do
          {response, body} = post(url, tool_request(version, name, valid, id), version, session_id)
          assert response.status == 200
          assert body["id"] == id
          assert body["result"]["structuredContent"] == expected
          assert_receive {:tool_dispatched, ^name, _validated}, 1000
          assert body["result"]["isError"] == false
          if version == "2026-07-28", do: assert(body["result"]["resultType"] == "complete")
          refute Map.has_key?(body, "error")
          if version == "2026-07-28", do: refute(header(response, "mcp-session-id"))
        end

        method = if version == "2026-07-28", do: "tools/list", else: "ping"
        {response, body} = post(url, request(version, method, %{}, 5), version, session_id)
        assert response.status == 200
        assert body["id"] == 5
        assert is_map(body["result"])
      end)

    refute log =~ "terminating"
    refute log =~ "FunctionClauseError"
    refute log =~ "CaseClauseError"
    assert Process.alive?(Process.whereis(Registry.task_supervisor_name(FixtureServer)))

    expected_sessions = if session_id, do: 1, else: 0
    assert DynamicSupervisor.count_children(session_supervisor).active == expected_sessions
    assert DynamicSupervisor.which_children(session_supervisor) == sessions
  end

  defp initialize_session(_url, "2026-07-28"), do: nil

  defp initialize_session(url, version) do
    params = %{
      "protocolVersion" => version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "custom-validation-client", "version" => "1.0.0"}
    }

    {response, body} = post(url, request(version, "initialize", params, 1), version)
    assert response.status == 200
    assert body["result"]["protocolVersion"] == version
    session_id = header(response, "mcp-session-id")
    assert is_binary(session_id)

    notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    {response, _body} = post(url, notification, version, session_id)
    assert response.status == 202
    session_id
  end

  defp tool_request(version, name, arguments, id) do
    request(version, "tools/call", %{"name" => name, "arguments" => arguments}, id)
  end

  defp request(version, method, params, id) do
    params =
      if version == "2026-07-28" do
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })
      else
        params
      end

    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp post(url, message, version, session_id \\ nil) do
    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", version}
    ]

    headers = if session_id, do: headers ++ [{"mcp-session-id", session_id}], else: headers

    headers =
      if version == "2026-07-28" do
        headers = headers ++ [{"mcp-method", message["method"]}]
        if message["method"] == "tools/call", do: headers ++ [{"mcp-name", message["params"]["name"]}], else: headers
      else
        headers
      end

    assert {:ok, response} =
             :post
             |> Finch.build(url, headers, JSON.encode!(message))
             |> Finch.request(Backplane.McpProtocol.Finch)

    body = if response.body == "", do: nil, else: JSON.decode!(response.body)
    {response, body}
  end

  defp header(response, name), do: response.headers |> List.keyfind(name, 0, {name, nil}) |> elem(1)
end
