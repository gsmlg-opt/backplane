defmodule Backplane.CDP.MCP.PagesTest do
  use ExUnit.Case, async: true

  alias Backplane.CDP.MCP.Pages

  defmodule ChromePlug do
    def init(browser), do: browser

    def call(conn, browser) do
      case conn.request_path do
        "/json/list" ->
          pages = Agent.get(browser, & &1.pages)

          json(
            conn,
            Enum.map(pages, fn page ->
              Map.merge(page, %{
                "type" => "page",
                "webSocketDebuggerUrl" =>
                  "ws://127.0.0.1:#{conn.port}/devtools/page/#{page["id"]}"
              })
            end)
          )

        "/json/version" ->
          json(conn, %{
            "webSocketDebuggerUrl" => "ws://127.0.0.1:#{conn.port}/devtools/browser/browser"
          })

        "/devtools/" <> path ->
          [_kind, target] = String.split(path, "/")

          Plug.Conn.upgrade_adapter(
            conn,
            :websocket,
            {Backplane.CDP.MCP.PagesTest.ChromeSocket, {browser, target}, []}
          )
      end
    end

    defp json(conn, value) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Formata.JSON.encode!(value))
    end
  end

  defmodule ChromeSocket do
    def init(state), do: {:ok, state}

    def handle_in({bytes, _metadata}, {browser, target} = state) do
      %{"id" => id, "method" => method, "params" => params} = Formata.JSON.decode!(bytes)

      result =
        Agent.get_and_update(browser, fn data ->
          data = %{data | requests: [{target, method, params} | data.requests]}
          command(method, params, target, data)
        end)

      {:push, {:text, Formata.JSON.encode!(%{"id" => id, "result" => result})}, state}
    end

    def handle_info(_message, state), do: {:ok, state}

    defp command("Target.createTarget", params, _target, data) do
      id = "page-#{data.next_target}"
      page = %{"id" => id, "title" => "", "url" => params["url"]}

      {%{"targetId" => id},
       %{data | pages: data.pages ++ [page], next_target: data.next_target + 1}}
    end

    defp command("Target.closeTarget", params, _target, data) do
      pages = Enum.reject(data.pages, &(&1["id"] == params["targetId"]))
      {%{"success" => true}, %{data | pages: pages}}
    end

    defp command("Target.createBrowserContext", _params, _target, data),
      do: {%{"browserContextId" => "context-1"}, data}

    defp command("Page.navigate", params, target, data) do
      pages =
        Enum.map(data.pages, fn page ->
          if page["id"] == target, do: Map.put(page, "url", params["url"]), else: page
        end)

      {%{"frameId" => "main", "loaderId" => "loaded"}, %{data | pages: pages}}
    end

    defp command("Page.getFrameTree", _params, target, data) do
      page = Enum.find(data.pages, &(&1["id"] == target))

      {%{
         "frameTree" => %{
           "frame" => %{"id" => "main", "url" => page["url"], "loaderId" => "loaded"}
         }
       }, data}
    end

    defp command("Runtime.evaluate", _params, _target, data),
      do: {%{"result" => %{"value" => "complete"}}, data}

    defp command("Browser.getWindowForTarget", _params, _target, data),
      do: {%{"windowId" => 7, "bounds" => %{"windowState" => "normal"}}, data}

    defp command(_method, _params, _target, data), do: {%{}, data}
  end

  setup do
    browser =
      start_supervised!(
        {Agent,
         fn ->
           %{
             pages: [%{"id" => "page-1", "title" => "First", "url" => "about:blank"}],
             requests: [],
             next_target: 2
           }
         end}
      )

    server =
      start_supervised!({Gaoxy.HTTP, plug: {ChromePlug, browser}, ip: {127, 0, 0, 1}, port: 0})

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    state = %{port: port, pages: %{}, selected: nil, next_id: 1, contexts: %{}, snapshots: %{}}
    %{browser: browser, state: state}
  end

  test "lists stable numeric IDs, selects pages, and protects the final tab", %{
    browser: browser,
    state: state
  } do
    assert {:ok, [%{"text" => "## Pages\n1: First (about:blank) [selected]"}], state} =
             Pages.call("list_pages", %{}, state)

    assert {:ok, [%{"text" => text}], state} = Pages.call("close_page", %{"pageId" => 1}, state)
    assert text =~ "The last open page cannot be closed. It is fine to keep it open."
    assert Agent.get(browser, & &1.requests) == []

    Agent.update(
      browser,
      &Map.update!(&1, :pages, fn pages ->
        pages ++ [%{"id" => "page-2", "title" => "Second", "url" => "https://example.test/"}]
      end)
    )

    assert {:ok, _blocks, state} =
             Pages.call("select_page", %{"pageId" => 2, "bringToFront" => true}, state)

    assert state.selected == 2
    assert {"page-2", "Page.bringToFront", %{}} in Agent.get(browser, & &1.requests)
    assert {:ok, "page-1", override} = Pages.selected(%{"pageId" => 1}, state)
    assert override.selected == 2
    assert {:error, "No page found", _state} = Pages.call("select_page", %{"pageId" => 22}, state)

    Agent.update(browser, &Map.update!(&1, :pages, fn pages -> Enum.reverse(pages) end))
    assert {:ok, _blocks, reordered} = Pages.call("list_pages", %{}, state)
    assert reordered.pages == %{1 => "page-1", 2 => "page-2"}

    assert {:ok, [%{"text" => remaining}], closed} =
             Pages.call("close_page", %{"pageId" => 2}, reordered)

    assert closed.selected == 1
    assert remaining =~ "1: First (about:blank) [selected]"
  end

  test "page list omits placeholder titles supplied by the Chrome discovery endpoint", %{
    browser: browser,
    state: state
  } do
    pages = [
      %{"id" => "blank", "title" => "about:blank", "url" => "about:blank"},
      %{"id" => "site", "title" => "example.test", "url" => "https://example.test/"}
    ]

    Agent.update(browser, &Map.put(&1, :pages, pages))

    assert {:ok, [%{"text" => "## Pages\n1: about:blank [selected]\n2: https://example.test/"}],
            _} =
             Pages.call("list_pages", %{}, state)
  end

  test "omits Chrome URL placeholder titles", %{browser: browser, state: state} do
    for {title, url} <- [
          {"about:blank", "about:blank"},
          {"https://example.test/", "https://example.test/"},
          {"example.test/", "https://example.test/"},
          {"example.test", "https://example.test/"}
        ] do
      Agent.update(browser, &%{&1 | pages: [%{"id" => "page-1", "title" => title, "url" => url}]})
      assert {:ok, [%{"text" => text}], _state} = Pages.call("list_pages", %{}, state)
      assert text == "## Pages\n1: #{url} [selected]"
    end
  end

  test "new pages reuse named isolated contexts and navigate the selected page", %{
    browser: browser,
    state: state
  } do
    args = %{
      "url" => "https://example.test/first",
      "isolatedContext" => "isolated",
      "background" => true
    }

    assert {:ok, [%{"text" => first}], state} = Pages.call("new_page", args, state)
    assert state.selected == 2
    assert first =~ "2: https://example.test/first [selected] isolatedContext=isolated"
    assert {:ok, _blocks, state} = Pages.call("new_page", args, state)
    requests = Agent.get(browser, & &1.requests)

    assert Enum.count(requests, fn {_target, method, _params} ->
             method == "Target.createBrowserContext"
           end) == 1

    assert {"browser", "Target.createTarget",
            %{"url" => "about:blank", "background" => true, "browserContextId" => "context-1"}} in requests

    assert {:ok, [%{"text" => text}], _state} =
             Pages.call("navigate_page", %{"url" => "https://example.test/second"}, state)

    assert text =~ "Successfully navigated to https://example.test/second."
    assert text =~ "3: https://example.test/second [selected]"
  end

  test "resizes browser contents with native CDP", %{browser: browser, state: state} do
    assert {:ok, _blocks, _state} =
             Pages.call("resize_page", %{"width" => 390, "height" => 844}, state)

    assert {"browser", "Browser.setContentsSize",
            %{"windowId" => 7, "width" => 390, "height" => 844}} in Agent.get(
             browser,
             & &1.requests
           )
  end

  test "rejects script injection and wrapped local file navigation before contacting Chrome", %{
    browser: browser,
    state: state
  } do
    for url <- [
          "javascript:alert(1)",
          "data:text/html,hello",
          "file:///etc/passwd",
          "view-source:file:///etc/passwd",
          "view-source:FILE:///etc/passwd",
          "devtools://devtools/"
        ] do
      assert {:error, _message, ^state} = Pages.call("new_page", %{"url" => url}, state)
      assert {:error, _message, ^state} = Pages.call("navigate_page", %{"url" => url}, state)
    end

    assert {:error, "JavaScript evaluation is disabled.", ^state} =
             Pages.call(
               "navigate_page",
               %{"url" => "about:blank", "initScript" => "alert(1)"},
               state
             )

    assert Agent.get(browser, & &1.requests) == []
  end
end
