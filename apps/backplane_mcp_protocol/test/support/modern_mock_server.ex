defmodule ModernMockServer do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "modern-mock-server",
    version: "1.0.0",
    capabilities: [
      {:tools, list_changed?: true},
      {:resources, list_changed?: true, subscribe?: true}
    ],
    protocol_versions: ["2026-07-28"]

  alias Backplane.McpProtocol.Server.Component.Schema
  alias Backplane.McpProtocol.Server.Frame
  alias Backplane.McpProtocol.Server.Modern.RequestContext
  alias Backplane.McpProtocol.Server.Registry
  alias Backplane.McpProtocol.Server.Response
  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  @test_pid_key {__MODULE__, :test_pid}

  @impl true
  def init_request(%RequestContext{} = context, frame) do
    notify({:modern_mock_request, context.method, context.headers})
    {:ok, register_components(frame)}
  end

  @impl true
  def init(_client_info, frame), do: {:ok, register_components(frame)}

  @impl true
  def handle_request(%{"method" => "tools/call", "params" => %{"name" => "mrtr"} = params}, frame) do
    case {params["requestState"], params["inputResponses"]} do
      {request_state,
       %{
         "sample" => %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => sampled_text},
           "model" => "dual-era-test"
         }
       }}
      when is_binary(request_state) and is_binary(sampled_text) ->
        result = %{
          "content" => [%{"type" => "text", "text" => "MRTR resolved"}],
          "structuredContent" => %{
            "resolved" => true,
            "requestState" => request_state,
            "sampledText" => sampled_text
          }
        }

        {:reply, result, frame}

      _initial ->
        request_state = "dual-era-#{System.unique_integer([:positive, :monotonic])}"
        notify({:modern_mock_mrtr_waiting, request_state})

        {:reply,
         %{
           "resultType" => "input_required",
           "requestState" => request_state,
           "inputRequests" => %{
             "sample" => %{
               "method" => "sampling/createMessage",
               "params" => %{
                 "messages" => [
                   %{
                     "role" => "user",
                     "content" => %{"type" => "text", "text" => "Resolve the test input"}
                   }
                 ],
                 "maxTokens" => 32
               }
             }
           }
         }, frame}
    end
  end

  def handle_request(request, frame) do
    Backplane.McpProtocol.Server.Handlers.handle(request, __MODULE__, frame)
  end

  @impl true
  def handle_tool_call("echo", arguments, frame) do
    {:reply, Response.structured(Response.tool(), arguments), frame}
  end

  def handle_tool_call("mrtr", _arguments, frame) do
    {:reply, Response.text(Response.tool(), "MRTR requires request context"), frame}
  end

  def mount_http(test_pid) when is_pid(test_pid) do
    :persistent_term.put(@test_pid_key, test_pid)
    bypass = Bypass.open()
    opts = StreamableHTTPPlug.init(server: __MODULE__)

    for method <- ["GET", "POST", "DELETE"] do
      Bypass.stub(bypass, method, "/mcp", fn conn ->
        StreamableHTTPPlug.call(conn, opts)
      end)
    end

    %{bypass: bypass, url: "http://127.0.0.1:#{bypass.port}"}
  end

  def await_subscription!(attempts \\ 100)

  def await_subscription!(0), do: raise("modern mock subscription did not open")

  def await_subscription!(attempts) do
    case __MODULE__ |> Registry.subscriptions_name() |> :sys.get_state() |> map_size(:subscriptions) do
      count when count > 0 ->
        :ok

      _count ->
        Process.sleep(10)
        await_subscription!(attempts - 1)
    end
  end

  defp map_size(state, field), do: state |> Map.fetch!(field) |> Kernel.map_size()

  def request(base_url, method, opts \\ []) when method in [:get, :delete] do
    url = base_url <> "/mcp"
    headers = Keyword.get(opts, :headers, [])

    method
    |> Finch.build(url, headers)
    |> Finch.request(Backplane.McpProtocol.Finch)
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
    {:ok, supervisor} =
      Backplane.McpProtocol.Server.Supervisor.start_link(__MODULE__, transport: :stdio)

    transport = Process.whereis(Registry.transport_name(__MODULE__, :stdio))
    ref = Process.monitor(transport)

    receive do
      {:DOWN, ^ref, :process, ^transport, _reason} ->
        Supervisor.stop(supervisor, :normal)
    end
  end

  defp register_components(frame) do
    frame
    |> Frame.register_tool("echo",
      description: "Echo integration-test arguments",
      input_schema:
        Schema.raw(%{
          "type" => "object",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"},
            "value" => %{"type" => "string"}
          },
          "additionalProperties" => false
        })
    )
    |> Frame.register_tool("mrtr",
      description: "Exercise multiple-round-trip input resolution",
      input_schema: Schema.raw(%{"type" => "object", "additionalProperties" => false})
    )
  end

  defp notify(message) do
    if test_pid = :persistent_term.get(@test_pid_key, nil), do: send(test_pid, message)
    :ok
  end
end
