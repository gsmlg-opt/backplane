defmodule Backplane.CDP.MCP.LighthouseTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Backplane.CDP.MCP.{Diagnostics, Lighthouse}

  defmodule Socket do
    def init(state), do: {:ok, state}

    def handle_in({bytes, _metadata}, {owner, browser} = state) do
      request = Formata.JSON.decode!(bytes)
      method = request["method"]
      params = request["params"]
      send(owner, {:command, method, params})

      {result, hold} =
        Agent.get_and_update(browser, fn data ->
          data = Map.update(data, :requests, [{method, params}], &(&1 ++ [{method, params}]))
          {result, data} = command(method, params, data)
          {{result, data.hold}, data}
        end)

      if method == "Runtime.evaluate" and
           String.contains?(params["expression"], "function backplaneLighthouseAudit") do
        send(owner, {:audit_started, self()})

        if hold,
          do: {:ok, {owner, browser, request["id"]}},
          else: response(request["id"], result, state)
      else
        response(request["id"], result, state)
      end
    end

    def handle_info(:finish_audit, {owner, browser, id}) do
      response(id, %{"result" => %{"value" => report()}}, {owner, browser})
    end

    defp response(id, result, state),
      do: {:push, {:text, Formata.JSON.encode!(%{"id" => id, "result" => result})}, state}

    defp command("Target.getDevToolsTarget", _params, %{frontend: nil} = data), do: {%{}, data}

    defp command("Target.getDevToolsTarget", _params, data),
      do: {%{"targetId" => data.frontend}, data}

    defp command("Target.openDevTools", _params, data),
      do: {%{"targetId" => "frontend-1"}, %{data | frontend: "frontend-1"}}

    defp command("Target.closeTarget", _params, data),
      do: {%{"success" => true}, %{data | frontend: nil}}

    defp command("Runtime.evaluate", %{"expression" => expression}, data) do
      value =
        cond do
          String.contains?(expression, "function backplaneLighthouseAudit") -> report()
          String.contains?(expression, "primaryPageTarget") -> true
          true -> nil
        end

      {%{"result" => %{"value" => value}}, data}
    end

    defp command(_method, _params, data), do: {%{}, data}

    def report do
      %{
        "lhr" => %{
          "lighthouseVersion" => "13.4.1",
          "runtimeError" => nil,
          "finalDisplayedUrl" => "https://example.test/",
          "audits" => %{"image-alt" => %{"score" => 0}}
        },
        "html" =>
          "<!doctype html><html><head><title>Lighthouse Report</title></head><body>Lighthouse 13.4.1</body></html>",
        "summary" => %{
          "mode" => "snapshot",
          "device" => "desktop",
          "url" => "https://example.test/",
          "scores" => [
            %{"id" => "accessibility", "title" => "Accessibility", "score" => 0.5},
            %{"id" => "seo", "title" => "SEO", "score" => nil}
          ],
          "audits" => %{"failed" => 1, "passed" => 2},
          "timing" => %{"total" => 12.5}
        },
        "failedAudits" => [
          %{
            "id" => "image-alt",
            "title" => "Images need alternate text",
            "score" => 0,
            "categories" => ["accessibility"],
            "description" => "Supply  alternate\ntext.",
            "nodes" => [
              %{"selector" => "#logo", "snippet" => "<img id=\"logo\">", "nodeLabel" => "Logo"}
            ],
            "totalNodes" => 1
          }
        ]
      }
    end
  end

  defmodule ChromePlug do
    def init(state), do: state

    def call(conn, {owner, browser} = state) do
      base = "ws://127.0.0.1:#{conn.port}"

      case conn.request_path do
        "/json/version" ->
          json(conn, %{"webSocketDebuggerUrl" => base <> "/devtools/browser/browser-1"})

        "/json/list" ->
          data = Agent.get(browser, & &1)

          pages = [
            %{
              "id" => "page-1",
              "type" => "page",
              "title" => "Fixture",
              "url" => "https://example.test/",
              "webSocketDebuggerUrl" => base <> "/devtools/page/page-1"
            }
          ]

          frontend =
            if data.frontend,
              do: [
                %{
                  "id" => data.frontend,
                  "type" => "page",
                  "title" => "DevTools",
                  "url" => "devtools://devtools/bundled/devtools_app.html",
                  "webSocketDebuggerUrl" => base <> "/devtools/page/#{data.frontend}"
                }
              ],
              else: []

          json(conn, pages ++ frontend)

        "/devtools/" <> _ ->
          Plug.Conn.upgrade_adapter(conn, :websocket, {Socket, state, []})

        _ ->
          send(owner, {:unexpected_path, conn.request_path})
          Plug.Conn.send_resp(conn, 404, "")
      end
    end

    defp json(conn, value),
      do:
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Formata.JSON.encode!(value))
  end

  setup do
    browser = start_supervised!({Agent, fn -> %{frontend: nil, hold: false} end})

    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {ChromePlug, {self(), browser}}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)

    state = %{
      port: port,
      pages: %{},
      selected: nil,
      next_id: 1,
      contexts: %{},
      snapshots: %{},
      observers: %{}
    }

    %{browser: browser, state: state}
  end

  test "renders audit evidence, writes reports, and closes its own frontend", %{
    browser: browser,
    state: state
  } do
    assert {:ok, [%{"text" => text}], _state} =
             Lighthouse.call("lighthouse_audit", %{"pageId" => 1, "mode" => "snapshot"}, state)

    assert text =~ "## Lighthouse audit results\nMode: snapshot\nDevice: desktop"
    assert text =~ "- Accessibility: 50 (accessibility)"
    assert text =~ "- SEO: n/a (seo)"
    assert text =~ "selector=\"#logo\""
    paths = report_paths(text)
    on_exit(fn -> Enum.each(paths, &File.rm/1) end)
    assert [json, html] = paths
    assert Formata.JSON.decode!(File.read!(json))["lighthouseVersion"] == "13.4.1"
    assert File.read!(html) =~ "Lighthouse Report"
    assert Agent.get(browser, & &1.frontend) == nil
    assert_received {:command, "Target.openDevTools", _params}
    assert_received {:command, "Target.closeTarget", %{"targetId" => "frontend-1"}}
  end

  test "named output uses report.json and report.html exclusively", %{
    state: state,
    tmp_dir: directory
  } do
    previous = System.get_env("BACKPLANE_CDP_ARTIFACT_DIR")
    System.put_env("BACKPLANE_CDP_ARTIFACT_DIR", directory)

    on_exit(fn ->
      if previous,
        do: System.put_env("BACKPLANE_CDP_ARTIFACT_DIR", previous),
        else: System.delete_env("BACKPLANE_CDP_ARTIFACT_DIR")
    end)

    args = %{"pageId" => 1, "mode" => "snapshot", "outputDirPath" => directory}
    assert {:ok, [%{"text" => text}], state} = Lighthouse.call("lighthouse_audit", args, state)

    assert report_paths(text) == [
             Path.join(directory, "report.json"),
             Path.join(directory, "report.html")
           ]

    original = File.read!(Path.join(directory, "report.json"))
    assert {:error, _message, _state} = Lighthouse.call("lighthouse_audit", args, state)
    assert File.read!(Path.join(directory, "report.json")) == original
  end

  test "preserves a pre-existing operator DevTools frontend", %{browser: browser, state: state} do
    Agent.update(browser, &%{&1 | frontend: "operator-frontend"})

    assert {:ok, [%{"text" => text}], _state} =
             Lighthouse.call("lighthouse_audit", %{"pageId" => 1, "mode" => "snapshot"}, state)

    on_exit(fn -> Enum.each(report_paths(text), &File.rm/1) end)
    assert Agent.get(browser, & &1.frontend) == "operator-frontend"
    refute_received {:command, "Target.openDevTools", _params}
    refute_received {:command, "Target.closeTarget", _params}
  end

  test "clears the original metrics cache and restores saved emulation after frontend close", %{
    browser: browser,
    state: state
  } do
    assert {:ok, _blocks, state} =
             Diagnostics.call(
               "emulate",
               %{"pageId" => 1, "viewport" => "390x844x3,mobile,touch"},
               state
             )

    Agent.update(browser, &Map.put(&1, :requests, []))

    assert {:ok, [%{"text" => text}], _state} =
             Lighthouse.call("lighthouse_audit", %{"pageId" => 1, "mode" => "snapshot"}, state)

    on_exit(fn -> Enum.each(report_paths(text), &File.rm/1) end)
    methods = Agent.get(browser, &Enum.map(&1.requests, fn {method, _params} -> method end))
    closed = Enum.find_index(methods, &(&1 == "Target.closeTarget"))
    cleared = Enum.find_index(methods, &(&1 == "Emulation.clearDeviceMetricsOverride"))
    restored = Enum.find_index(methods, &(&1 == "Emulation.setDeviceMetricsOverride"))
    assert is_integer(closed) and closed < cleared and cleared < restored
  end

  test "serializes audits across MCP owners and cleans up after owner death", %{
    browser: browser,
    state: state
  } do
    Agent.update(browser, &%{&1 | hold: true})

    owner =
      spawn(fn ->
        Lighthouse.call("lighthouse_audit", %{"pageId" => 1, "mode" => "snapshot"}, state)
      end)

    assert_receive {:audit_started, _socket}, 3_000

    assert {:error, "A Lighthouse audit is already running for this page.", _state} =
             Lighthouse.call("lighthouse_audit", %{"pageId" => 1, "mode" => "snapshot"}, state)

    Process.exit(owner, :shutdown)
    assert_receive {:command, "Target.closeTarget", %{"targetId" => "frontend-1"}}, 3_000
  end

  defp report_paths(text) do
    [_summary, reports] = String.split(text, "### Reports\n")
    reports |> String.split("\n") |> Enum.map(&String.replace_prefix(&1, "- ", ""))
  end
end
