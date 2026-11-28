defmodule Backplane.CDP.MCP.InteractionTest do
  use ExUnit.Case, async: true

  alias Backplane.CDP.MCP.Interaction

  defmodule ChromeSocket do
    def init({owner, store}),
      do: {:ok, %{owner: owner, store: store, objects: %{}, next_object: 1, intercept: false}}

    def handle_in({bytes, _metadata}, state) do
      request = Formata.JSON.decode!(bytes)
      send(state.owner, {:command, self(), request["method"], request["params"]})
      {result, state} = respond(request["method"], request["params"], state)
      reply = %{"id" => request["id"], "result" => result}

      event = %{
        "method" => "Input.dragIntercepted",
        "params" => %{"data" => %{"items" => [], "dragOperationsMask" => 1}}
      }

      events =
        if request["method"] == "Input.dispatchMouseEvent" and request["params"]["buttons"] == 1 and
             state.intercept,
           do: [event],
           else: []

      {:push, Enum.map(events ++ [reply], &{:text, Formata.JSON.encode!(&1)}), state}
    end

    def handle_info(_message, state), do: {:ok, state}

    defp respond("Page.getFrameTree", _params, state),
      do:
        {%{"frameTree" => %{"frame" => %{"loaderId" => Agent.get(state.store, & &1.loader)}}},
         state}

    defp respond("Accessibility.getFullAXTree", _params, state) do
      {%{
         "nodes" => [
           %{
             "nodeId" => "1",
             "backendDOMNodeId" => 1,
             "role" => %{"value" => "RootWebArea"},
             "name" => %{"value" => "Fixture"},
             "childIds" => ["2", "3"]
           },
           %{
             "nodeId" => "2",
             "parentId" => "1",
             "backendDOMNodeId" => 2,
             "role" => %{"value" => "textbox"},
             "name" => %{"value" => "Email"}
           },
           %{
             "nodeId" => "3",
             "parentId" => "1",
             "backendDOMNodeId" => 3,
             "role" => %{"value" => "button"},
             "name" => %{"value" => "Submit"}
           }
         ]
       }, state}
    end

    defp respond("DOM.resolveNode", %{"backendNodeId" => backend}, state) do
      object = "node-#{state.next_object}"

      {%{"object" => %{"objectId" => object}},
       %{
         state
         | objects: Map.put(state.objects, object, backend),
           next_object: state.next_object + 1
       }}
    end

    defp respond("Runtime.evaluate", %{"expression" => "document"}, state) do
      {%{"result" => %{"objectId" => "document"}},
       %{state | objects: Map.put(state.objects, "document", :document)}}
    end

    defp respond("Runtime.callFunctionOn", params, state) do
      if Map.has_key?(state.objects, params["objectId"]) do
        function = params["functionDeclaration"]

        value =
          cond do
            String.contains?(function, "HTMLOptionElement") ->
              false

            String.contains?(function, "Element is obscured") ->
              %{"x" => 20, "y" => 30}

            String.contains?(function, "screenshot area") ->
              %{"x" => 5, "y" => 6, "width" => 100, "height" => 50}

            true ->
              true
          end

        {%{"result" => %{"value" => value}}, state}
      else
        {%{"exceptionDetails" => %{"text" => "object ID belongs to another connection"}}, state}
      end
    end

    defp respond("Page.captureScreenshot", _params, state),
      do: {%{"data" => Base.encode64("image bytes")}, state}

    defp respond("Page.getLayoutMetrics", _params, state),
      do: {%{"cssContentSize" => %{"x" => 0, "y" => 0, "width" => 1000, "height" => 2000}}, state}

    defp respond("Input.setInterceptDrags", %{"enabled" => enabled}, state),
      do: {%{}, %{state | intercept: enabled}}

    defp respond(_method, _params, state), do: {%{}, state}
  end

  defmodule ChromePlug do
    def init(state), do: state

    def call(conn, state) do
      case conn.request_path do
        "/json/list" ->
          Plug.Conn.send_resp(
            conn,
            200,
            Formata.JSON.encode!([
              %{
                "id" => "page-1",
                "type" => "page",
                "title" => "Fixture",
                "url" => "http://fixture.test",
                "webSocketDebuggerUrl" => "ws://127.0.0.1:#{conn.port}/devtools/page/page-1"
              }
            ])
          )

        "/devtools/page/page-1" ->
          Plug.Conn.upgrade_adapter(conn, :websocket, {ChromeSocket, state, []})
      end
    end
  end

  setup do
    store = start_supervised!({Agent, fn -> %{loader: "loader-1"} end})

    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {ChromePlug, {self(), store}}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    state = %{port: port, pages: %{}, selected: nil, next_id: 1, snapshots: %{}}
    {:ok, _blocks, state} = Interaction.call("take_snapshot", %{}, state)
    uid = state.snapshots["page-1"].by_backend[2]
    button_uid = state.snapshots["page-1"].by_backend[3]
    %{state: state, uid: uid, button_uid: button_uid, store: store}
  end

  test "fill resolves the UID and invokes a fixed function on the same connection", %{
    state: state,
    uid: uid
  } do
    assert {:ok, [%{"text" => "Successfully filled out the element"}], _state} =
             Interaction.call("fill", %{"uid" => uid, "value" => "value');evil()"}, state)

    assert_receive {:command, socket, "DOM.resolveNode", %{"backendNodeId" => 2}}

    assert_receive {:command, ^socket, "Runtime.callFunctionOn",
                    %{
                      "arguments" => [%{"value" => "value');evil()"}],
                      "functionDeclaration" => function
                    }}

    refute function =~ "evil()"
  end

  test "click and hover dispatch native mouse input and can include a snapshot", %{
    state: state,
    uid: uid
  } do
    assert {:ok, [%{"text" => text}], state} =
             Interaction.call(
               "click",
               %{"uid" => uid, "dblClick" => true, "includeSnapshot" => true},
               state
             )

    assert text =~ "Successfully double clicked"
    assert text =~ "## Latest page snapshot"

    assert_receive {:command, _, "Input.dispatchMouseEvent",
                    %{"type" => "mousePressed", "clickCount" => 1}}

    assert_receive {:command, _, "Input.dispatchMouseEvent",
                    %{"type" => "mousePressed", "clickCount" => 2}}

    assert {:ok, _, _} = Interaction.call("hover", %{"uid" => uid}, state)
    assert_receive {:command, _, "Input.dispatchMouseEvent", %{"type" => "mouseMoved"}}
  end

  test "fill form processes element UIDs sequentially", %{state: state, uid: uid} do
    assert {:ok, [%{"text" => "Successfully filled out the form"}], _} =
             Interaction.call(
               "fill_form",
               %{"elements" => [%{"uid" => uid, "value" => "email@example.org"}]},
               state
             )
  end

  test "screenshots preserve image content blocks and full-page clip", %{state: state} do
    assert {:ok,
            [
              %{"type" => "text"},
              %{"type" => "image", "mimeType" => "image/webp", "data" => data}
            ],
            _} =
             Interaction.call(
               "take_screenshot",
               %{
                 "format" => "webp",
                 "fullPage" => true,
                 "omitBackground" => true,
                 "quality" => 80
               },
               state
             )

    assert Base.decode64!(data) == "image bytes"

    assert_receive {:command, _, "Page.captureScreenshot",
                    %{"format" => "webp", "clip" => %{"height" => 2000}, "quality" => 80}}

    assert_receive {:command, _, "Emulation.setDefaultBackgroundColorOverride", %{}}
  end

  test "keyboard shortcuts release their modifiers and type_text supports submitKey", %{
    state: state
  } do
    assert {:ok, _, _} = Interaction.call("press_key", %{"key" => "Control+A"}, state)

    assert_receive {:command, _, "Input.dispatchKeyEvent",
                    %{"type" => "rawKeyDown", "key" => "Control", "modifiers" => 2}}

    assert_receive {:command, _, "Input.dispatchKeyEvent",
                    %{"type" => "keyUp", "key" => "Control", "modifiers" => 0}}

    assert {:ok, _, _} =
             Interaction.call("type_text", %{"text" => "Hello", "submitKey" => "Enter"}, state)

    assert_receive {:command, _, "Input.insertText", %{"text" => "Hello"}}
  end

  test "drag forwards the intercepted browser payload through native drag events", %{
    state: state,
    uid: uid,
    button_uid: button_uid
  } do
    assert {:ok, [%{"text" => "Successfully dragged an element"}], _} =
             Interaction.call("drag", %{"from_uid" => uid, "to_uid" => button_uid}, state)

    assert_receive {:command, _, "Input.dispatchDragEvent",
                    %{"type" => "drop", "data" => %{"dragOperationsMask" => 1}}}

    assert_receive {:command, _, "Input.setInterceptDrags", %{"enabled" => false}}
  end

  test "wait_for returns a new snapshot after matching text", %{state: state} do
    assert {:ok, [%{"text" => text}], _} =
             Interaction.call("wait_for", %{"text" => ["Hello"], "visible" => true}, state)

    assert text =~ "Element matching one of [\"Hello\"] found."
    assert text =~ "## Latest page snapshot"
  end

  test "stale document UIDs fail before interacting", %{state: state, uid: uid, store: store} do
    Agent.update(store, &%{&1 | loader: "loader-2"})

    assert {:error, "The page changed since the last snapshot. Take a new snapshot.", _} =
             Interaction.call("fill", %{"uid" => uid, "value" => "x"}, state)

    refute_receive {:command, _, "DOM.resolveNode", _}
  end

  test "unsupported and malformed options return explicit errors", %{state: state, uid: uid} do
    assert {:error, "Unsupported options: arbitrary", _} =
             Interaction.call("click", %{"uid" => uid, "arbitrary" => true}, state)

    assert {:error, _, _} =
             Interaction.call("take_screenshot", %{"uid" => uid, "fullPage" => true}, state)

    assert {:error, _, _} =
             Interaction.call("fill_form", %{"elements" => [%{"uid" => uid}]}, state)

    assert {:error, _, _} = Interaction.call("wait_for", %{"text" => []}, state)

    assert {:error, _, _} =
             Interaction.call(
               "type_text",
               %{"text" => "hello", "submitKey" => "Control+A"},
               state
             )
  end

  test "parses plus keys and rejects duplicate modifiers" do
    assert {:ok, ["Control", "+"]} = Interaction.parse_keys("Control++")
    assert {:ok, ["Control", "Shift", "R"]} = Interaction.parse_keys("Control+Shift+R")
    assert {:error, _} = Interaction.parse_keys("Control+Control+A")
  end
end
