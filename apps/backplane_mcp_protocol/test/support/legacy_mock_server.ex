defmodule LegacyMockServer do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "legacy-mock-server",
    version: "1.0.0",
    capabilities: [:tools],
    protocol_versions: ["2025-11-25", "2025-06-18"]

  import Plug.Conn

  alias Backplane.McpProtocol.Server.Component.Schema
  alias Backplane.McpProtocol.Server.Frame
  alias Backplane.McpProtocol.Server.Response
  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  @test_pid_key {__MODULE__, :test_pid}

  @impl true
  def init(_client_info, frame) do
    notify(:legacy_mock_initialized)
    {:ok, register_components(frame)}
  end

  @impl true
  def handle_tool_call("legacy_echo", arguments, frame) do
    {:reply, Response.structured(Response.tool(), arguments), frame}
  end

  def mount_http(test_pid) when is_pid(test_pid) do
    :persistent_term.put(@test_pid_key, test_pid)
    bypass = Bypass.open()
    opts = StreamableHTTPPlug.init(server: __MODULE__)

    for method <- ["GET", "POST", "DELETE"] do
      Bypass.stub(bypass, method, "/mcp", fn conn ->
        if get_req_header(conn, "mcp-method") == ["server/discover"] do
          send(test_pid, :legacy_mock_discovery_refused)

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(404, "method not found")
        else
          StreamableHTTPPlug.call(conn, opts)
        end
      end)
    end

    %{bypass: bypass, url: "http://127.0.0.1:#{bypass.port}"}
  end

  def stdio_transport do
    code = inspect(__MODULE__) <> ".stdio_main()"

    {:stdio,
     command: System.find_executable("mix"),
     args: ["run", "-e", code],
     cwd: File.cwd!(),
     env: %{
       "MIX_ENV" => "test",
       "MIX_DEPS_PATH" => Mix.Project.deps_path()
     }}
  end

  def stdio_main do
    :logger.update_handler_config(:default, :config, %{type: :standard_error})
    stdio_loop()
  end

  defp stdio_loop do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      line when is_binary(line) ->
        line
        |> JSON.decode!()
        |> legacy_response()
        |> maybe_write_response()

        stdio_loop()
    end
  end

  defp legacy_response(%{"id" => id, "method" => "server/discover"}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    }
  end

  defp legacy_response(%{"id" => id, "method" => "initialize"}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "legacy-mock-server", "version" => "1.0.0"}
      }
    }
  end

  defp legacy_response(%{"id" => id, "method" => "tools/list"}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => [
          %{
            "name" => "legacy_echo",
            "description" => "Echo legacy arguments",
            "inputSchema" => %{"type" => "object", "additionalProperties" => true}
          }
        ]
      }
    }
  end

  defp legacy_response(%{"id" => id, "method" => "tools/call", "params" => %{"arguments" => arguments}}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "content" => [%{"type" => "text", "text" => JSON.encode!(arguments)}],
        "structuredContent" => arguments,
        "isError" => false
      }
    }
  end

  defp legacy_response(%{"id" => id, "method" => "ping"}) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}
  end

  defp legacy_response(%{"id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    }
  end

  defp legacy_response(_notification), do: nil

  defp maybe_write_response(nil), do: :ok

  defp maybe_write_response(response) do
    IO.binwrite(:stdio, JSON.encode!(response) <> "\n")
  end

  defp register_components(frame) do
    Frame.register_tool(frame, "legacy_echo",
      description: "Echo legacy arguments",
      input_schema: Schema.raw(%{"type" => "object", "additionalProperties" => true})
    )
  end

  defp notify(message) do
    if test_pid = :persistent_term.get(@test_pid_key, nil), do: send(test_pid, message)
    :ok
  end
end
