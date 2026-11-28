defmodule Backplane.HostAgent.CDPTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.MemoryRouter
  alias Backplane.HostAgent.Services.CDP

  import Plug.Conn
  import Plug.Test

  defmodule HubProxy do
    def list_tools do
      {:ok,
       [
         %{"name" => "cdp::remote_browser", "description" => "remote CDP tool"},
         %{"name" => "cdp::list_pages", "description" => "remote list pages"}
       ]}
    end

    def call_tool(name, args), do: {:ok, %{"remote" => name, "arguments" => args}}
  end

  defmodule ChromePlug do
    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/json/list" ->
          body =
            Formata.JSON.encode!([
              %{
                "type" => "page",
                "id" => "page-1",
                "title" => "Host agent CDP test",
                "url" => "about:blank",
                "webSocketDebuggerUrl" => "ws://127.0.0.1:#{conn.port}/devtools/page/page-1"
              }
            ])

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end
  end

  setup do
    previous_port = System.get_env("BACKPLANE_CDP_PORT")
    previous_cdp = Application.get_env(:backplane_cdp, :config)
    previous_proxy = Application.fetch_env(:backplane_host_agent, :hub_proxy_module)
    Application.delete_env(:backplane_cdp, :config)
    System.delete_env("BACKPLANE_CDP_PORT")
    Application.put_env(:backplane_host_agent, :hub_proxy_module, HubProxy)

    on_exit(fn ->
      if previous_cdp,
        do: Application.put_env(:backplane_cdp, :config, previous_cdp),
        else: Application.delete_env(:backplane_cdp, :config)

      if previous_port,
        do: System.put_env("BACKPLANE_CDP_PORT", previous_port),
        else: System.delete_env("BACKPLANE_CDP_PORT")

      case previous_proxy do
        {:ok, proxy} -> Application.put_env(:backplane_host_agent, :hub_proxy_module, proxy)
        :error -> Application.delete_env(:backplane_host_agent, :hub_proxy_module)
      end
    end)

    :ok
  end

  test "disabled local CDP preserves remote discovery and dispatch" do
    assert CDP.tools() == []

    remote_tools = tools() |> Enum.filter(&String.starts_with?(&1["name"], "cdp::"))
    assert Enum.map(remote_tools, & &1["name"]) == ["cdp::remote_browser", "cdp::list_pages"]

    assert %{
             "result" => %{
               "isError" => false,
               "content" => [%{"type" => "text", "text" => result}]
             }
           } = call_tool("cdp::list_pages", %{})

    assert Formata.JSON.decode!(result) == %{"remote" => "cdp::list_pages", "arguments" => %{}}
  end

  @tag :tmp_dir
  test "TOML config selects the Chrome instance used by the MCP route", %{tmp_dir: dir} do
    chrome =
      start_supervised!({Gaoxy.HTTP, plug: {ChromePlug, []}, ip: {127, 0, 0, 1}, port: 0})

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(chrome, :http)
    path = Path.join(dir, "host_agent.toml")
    File.write!(path, "[cdp]\nenabled = true\nport = #{port}\n")
    {:ok, config} = Backplane.HostAgent.Config.load(path)
    :ok = CDP.configure(config)

    descriptors = tools()
    assert [local_list] = Enum.filter(descriptors, &(&1["name"] == "cdp::list_pages"))
    refute local_list["description"] == "remote list pages"
    assert Enum.any?(descriptors, &(&1["name"] == "cdp::remote_browser"))

    for tool <- Enum.filter(descriptors, &String.starts_with?(&1["name"], "cdp::")) do
      assert %{"type" => "object"} = tool["inputSchema"]
    end

    assert %{
             "result" => %{
               "isError" => false,
               "content" => [%{"type" => "text", "text" => pages}]
             }
           } = rpc("tools/call", %{"name" => "cdp::list_pages"})

    assert pages =~ "## Pages"
    assert pages =~ "about:blank"
    assert pages =~ "[selected]"

    assert %{
             "result" => %{
               "isError" => false,
               "content" => [%{"text" => remote}]
             }
           } = call_tool("cdp::remote_browser", %{"key" => "value"})

    assert Formata.JSON.decode!(remote) == %{
             "remote" => "cdp::remote_browser",
             "arguments" => %{"key" => "value"}
           }
  end

  test "local CDP validation errors are MCP tool errors" do
    System.put_env("BACKPLANE_CDP_PORT", "9222")

    assert %{
             "result" => %{
               "isError" => true,
               "content" => [%{"type" => "text", "text" => message}]
             }
           } = call_tool("cdp::take_screenshot", %{})

    assert is_binary(message) and message != ""
  end

  test "dedicated endpoint keeps the upstream names and schemas, with isolated sessions" do
    path = "/mcp/chrome-devtools"

    build = fn method, params ->
      Formata.JSON.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})
    end

    post = fn body, token ->
      conn = conn(:post, path, body) |> put_req_header("content-type", "application/json")
      conn = if token, do: put_req_header(conn, "mcp-session-id", token), else: conn
      MemoryRouter.call(conn, MemoryRouter.init([]))
    end

    initialize = build.("initialize", %{"protocolVersion" => "2025-11-25"})
    assert post.(initialize, nil).status == 404
    System.put_env("BACKPLANE_CDP_PORT", "9222")

    assert conn(:post, path, initialize)
           |> put_req_header("content-type", "application/json")
           |> put_req_header("origin", "https://external.example")
           |> MemoryRouter.call([])
           |> Map.fetch!(:status) == 403

    first = post.(initialize, nil)
    [token] = get_resp_header(first, "mcp-session-id")
    assert first.status == 200
    [other] = post.(initialize, nil) |> get_resp_header("mcp-session-id")
    assert token != other

    catalog =
      :backplane_cdp
      |> :code.priv_dir()
      |> Path.join("chrome_devtools_mcp/1.14.0.json")
      |> File.read!()
      |> Formata.JSON.decode!()
      |> Map.new(&{&1["name"], &1})

    tools =
      post.(build.("tools/list", %{}), token)
      |> Map.fetch!(:resp_body)
      |> Formata.JSON.decode!()
      |> get_in(["result", "tools"])

    assert Map.new(tools, &{&1["name"], &1}) == catalog
    assert length(tools) == map_size(catalog)

    assert Map.new(CDP.tools(), fn %{"name" => "cdp::" <> name} = tool ->
             {name, Map.put(tool, "name", name)}
           end) == catalog

    assert Enum.find(tools, &(&1["name"] == "click"))["inputSchema"]["required"] == [
             "pageId",
             "uid"
           ]

    wrong =
      post.(
        build.("tools/call", %{"name" => "click", "arguments" => %{"x" => 1, "y" => 1}}),
        token
      )

    assert Formata.JSON.decode!(wrong.resp_body)["result"]["isError"]
    assert post.(build.("tools/list", %{}), nil).status == 400
    assert post.(build.("tools/list", %{}), "missing").status == 404

    assert conn(:delete, path)
           |> put_req_header("mcp-session-id", token)
           |> MemoryRouter.call([])
           |> Map.fetch!(:status) == 200

    assert post.(build.("tools/list", %{}), token).status == 404
    assert post.(build.("tools/list", %{}), other).status == 200
    conn(:delete, path) |> put_req_header("mcp-session-id", other) |> MemoryRouter.call([])
  end

  defp tools, do: rpc("tools/list", %{})["result"]["tools"]

  defp call_tool(name, arguments) do
    rpc("tools/call", %{"name" => name, "arguments" => arguments})
  end

  defp rpc(method, params) do
    body =
      Formata.JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => params
      })

    conn =
      :post
      |> conn("/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> MemoryRouter.call(MemoryRouter.init([]))

    assert conn.status == 200
    Formata.JSON.decode!(conn.resp_body)
  end
end
