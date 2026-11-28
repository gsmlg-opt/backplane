defmodule Backplane.HostAgent.CDPBrowserTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.HostAgent.MemoryRouter

  # Set this to the loopback debugging port of a disposable Chromium profile.
  @browser_port System.get_env("BACKPLANE_CDP_TEST_PORT")
  if is_nil(@browser_port), do: @moduletag(skip: "requires BACKPLANE_CDP_TEST_PORT")

  defmodule Fixture do
    def init(opts), do: opts

    def call(conn, store) do
      {type, body} =
        case conn.request_path do
          "/app.js" ->
            padding = Agent.get(store, & &1)

            {"application/javascript",
             padding <>
               """
               document.querySelector('button').onclick = function () {
                 const count = 7;
                 document.body.dataset.count = count;
               };
               //# sourceMappingURL=app.js.map
               """}

          "/app.js.map" ->
            padding = Agent.get(store, & &1)

            map = %{
              version: 3,
              sources: ["src/source.ts"],
              names: [],
              mappings: if(padding == "", do: ";;AAEA", else: ";;;AAEA")
            }

            {"application/json", Formata.JSON.encode!(map)}

          _ ->
            {"text/html",
             "<!doctype html><html lang=en><title>CDP fixture</title><button>Run</button><script src=/app.js></script></html>"}
        end

      conn |> put_resp_content_type(type) |> send_resp(200, body)
    end
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "agent debugging and profiling through the dedicated Chrome DevTools MCP route", %{
    tmp_dir: dir
  } do
    previous = Application.get_env(:backplane_cdp, :config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_cdp, :config, previous),
        else: Application.delete_env(:backplane_cdp, :config)
    end)

    path = Path.join(dir, "host_agent.toml")

    File.write!(path, """
    [cdp]
    port = #{@browser_port}
    artifact_dir = "."
    upload_dir = "."
    """)

    {:ok, config} = Backplane.HostAgent.Config.load(path)
    :ok = Backplane.HostAgent.Services.CDP.configure(config)

    store = start_supervised!({Agent, fn -> "" end})

    listener =
      start_supervised!({Gaoxy.HTTP, plug: {Fixture, store}, ip: {127, 0, 0, 1}, port: 0})

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(listener, :http)
    url = "http://127.0.0.1:#{port}/"

    [session] = rpc(nil, "initialize", %{}) |> get_resp_header("mcp-session-id")

    on_exit(fn ->
      conn(:delete, "/mcp/chrome-devtools")
      |> put_req_header("mcp-session-id", session)
      |> MemoryRouter.call([])
    end)

    {:ok, pages} = tool(session, "new_page", %{"url" => url})
    [_, id] = Regex.run(~r/(\d+): [^\n]*\[selected\]/, pages)
    page = %{"pageId" => String.to_integer(id)}
    on_exit(fn -> tool(session, "close_page", page) end)
    call = fn name, args -> tool(session, name, Map.merge(page, args)) end

    {:ok, snapshot} = call.("take_snapshot", %{})
    [_, uid] = Regex.run(~r/uid=(\S+) button/, snapshot)

    assert {:ok, text} =
             call.("evaluate_script", %{
               "function" => "(el) => ({text: el.innerText})",
               "args" => [uid]
             })

    assert text =~ ~s({"text":"Run"})

    assert {:ok, text} = call.("evaluate_script", %{"function" => "async () => document.title"})
    assert text =~ ~s("CDP fixture")
    File.write!(Path.join(dir, "title.js"), "document.title")

    assert {:ok, _} =
             call.("evaluate_script", %{
               "format" => "script",
               "sourcePath" => "title.js",
               "filePath" => "result.txt"
             })

    assert File.read!(Path.join(dir, "result.json")) == ~s("CDP fixture")

    assert {:error, msg} =
             call.("evaluate_script", %{"function" => "() => document.title = 'Changed'"})

    assert msg =~ "side-effect"

    set = fn entries -> call.("set_logpoints", %{"logpoints" => entries}) end
    assert {:ok, text} = set.(["src/source.ts:3 'first', count"])
    assert text =~ "bound via source map at #{url}app.js:3"
    assert {:ok, _} = call.("click", %{"uid" => uid})
    assert {:ok, log} = call.("list_console_messages", %{})
    assert log =~ "first 7"

    assert {:ok, _} = set.(["src/source.ts:3 'second', count"])
    Agent.update(store, fn _ -> "\n" end)
    assert {:ok, _} = call.("navigate_page", %{"type" => "reload", "ignoreCache" => true})

    assert {:error, _} =
             call.("evaluate_script", %{"function" => "el => el.innerText", "args" => [uid]})

    {:ok, snapshot} = call.("take_snapshot", %{})
    [_, fresh] = Regex.run(~r/uid=(\S+) button/, snapshot)

    assert eventually(fn ->
             {:ok, _} = call.("click", %{"uid" => fresh})
             {:ok, text} = call.("list_console_messages", %{})
             text =~ "second 7" and not (text =~ "first 7")
           end)

    assert {:ok, "No logpoints are set on the page."} = set.([])
    {:ok, before_clear} = call.("list_console_messages", %{})
    assert {:ok, _} = call.("click", %{"uid" => fresh})
    assert {:ok, ^before_clear} = call.("list_console_messages", %{})

    assert {:ok, text} = call.("take_heapsnapshot", %{"filePath" => "fixture"})
    assert text =~ "Heap snapshot saved to "

    assert %{"snapshot" => %{"node_count" => count}, "nodes" => [_ | _]} =
             Path.join(dir, "fixture.heapsnapshot") |> File.read!() |> Formata.JSON.decode!()

    assert count > 0

    assert {:ok, _} = call.("emulate", %{"viewport" => "390x844x3,mobile"})

    metrics = %{
      "function" => "() => [innerWidth, innerHeight, devicePixelRatio]",
      "waitForStableDom" => false
    }

    assert {:ok, before_audit} = call.("evaluate_script", metrics)
    assert before_audit =~ ",3]"

    assert {:ok, report} =
             call.("lighthouse_audit", %{"mode" => "snapshot", "outputDirPath" => dir})

    assert {:ok, ^before_audit} = call.("evaluate_script", metrics)
    assert report =~ "## Lighthouse audit results"
    lhr = Path.join(dir, "report.json") |> File.read!() |> Formata.JSON.decode!()
    assert lhr["finalDisplayedUrl"] == url
    assert is_binary(lhr["lighthouseVersion"])
    assert Map.has_key?(lhr["audits"], "document-title")
    assert File.read!(Path.join(dir, "report.html")) =~ "Lighthouse"
  end

  defp eventually(fun, tries \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, tries - 1)
    end
  end

  defp tool(session, name, args) do
    %{"result" => result} =
      rpc(session, "tools/call", %{"name" => name, "arguments" => args}).resp_body
      |> Formata.JSON.decode!()

    [%{"text" => text}] = result["content"]
    if result["isError"], do: {:error, text}, else: {:ok, text}
  end

  defp rpc(session, method, params) do
    body = Formata.JSON.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})

    req =
      conn(:post, "/mcp/chrome-devtools", body)
      |> put_req_header("content-type", "application/json")

    req = if session, do: put_req_header(req, "mcp-session-id", session), else: req
    MemoryRouter.call(req, MemoryRouter.init([]))
  end
end
