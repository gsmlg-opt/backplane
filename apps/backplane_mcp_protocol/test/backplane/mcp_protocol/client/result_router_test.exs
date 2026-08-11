defmodule Backplane.McpProtocol.Client.ResultRouterTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Client.MRTR
  alias Backplane.McpProtocol.Client.Request
  alias Backplane.McpProtocol.Client.ResultRouter
  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Response

  test "modern complete and extension results are terminal" do
    request = request("tools/call")
    state = state(:modern)

    for result_type <- ["complete", "com.example/deferred"] do
      result = %{"resultType" => result_type, "value" => 42}

      assert {:complete, %Response{} = response, ^state} =
               ResultRouter.route(request, result, state)

      assert response.id == request.id
      assert response.result == result
      assert response.result_type == result_type
    end
  end

  test "modern peers default an omitted resultType to complete but reject invalid values" do
    request = request("prompts/get")

    assert {:complete, %Response{result: %{"description" => "missing"}, result_type: "complete"}, _state} =
             ResultRouter.route(request, %{"description" => "missing"}, state(:modern))

    assert {:error, %Error{reason: :malformed_response}, _state} =
             ResultRouter.route(request, %{"resultType" => 7}, state(:modern))

    assert {:complete, %Response{result: %{"description" => "legacy"}}, _state} =
             ResultRouter.route(request, %{"description" => "legacy"}, state(:legacy))

    assert {:error, %Error{reason: :malformed_response}, _state} =
             ResultRouter.route(request, "not-an-object", state(:modern))

    assert {:complete, %Response{result: "legacy-scalar"}, _state} =
             ResultRouter.route(request, "legacy-scalar", state(:legacy))

    assert {:complete, %Response{result: %{"resultType" => 7}}, _state} =
             ResultRouter.route(request, %{"resultType" => 7}, state(:legacy))
  end

  test "legacy input_required-shaped results remain terminal" do
    request = request("tools/call")
    result = %{"resultType" => "input_required", "requestState" => "legacy-opaque"}

    assert {:complete, %Response{result: ^result}, _state} =
             ResultRouter.route(request, result, state(:legacy))
  end

  test "only the three MRTR methods may enter input_required" do
    result = %{"resultType" => "input_required", "inputRequests" => %{}}

    for method <- ~w(tools/call prompts/get resources/read) do
      assert {:input_required, %MRTR{method: ^method}, _state} =
               ResultRouter.route(request(method), result, state(:modern))
    end

    assert {:error, %Error{reason: :malformed_response}, _state} =
             ResultRouter.route(request("tools/list"), result, state(:modern))
  end

  test "input_required validates field presence and shape without exposing opaque values" do
    request = request("tools/call")
    modern = state(:modern)

    malformed = [
      %{"resultType" => "input_required"},
      %{"resultType" => "input_required", "inputRequests" => nil},
      %{"resultType" => "input_required", "inputRequests" => []},
      %{"resultType" => "input_required", "requestState" => nil},
      %{"resultType" => "input_required", "requestState" => 7}
    ]

    for result <- malformed do
      assert {:error, %Error{reason: :malformed_response} = error, ^modern} =
               ResultRouter.route(request, result, modern)

      refute inspect(error) =~ "requestState"
      refute inspect(error) =~ "inputRequests"
    end

    assert {:input_required, %MRTR{input_requests_present?: true, input_requests: %{}}, _state} =
             ResultRouter.route(
               request,
               %{"resultType" => "input_required", "inputRequests" => %{}},
               modern
             )

    assert {:input_required, %MRTR{input_requests_present?: false, request_state: "opaque-state"}, _state} =
             ResultRouter.route(
               request,
               %{"resultType" => "input_required", "requestState" => "opaque-state"},
               modern
             )
  end

  defp request(method) do
    Request.new(%{
      id: "wire-1",
      method: method,
      from: {self(), make_ref()},
      timer_ref: make_ref(),
      params: %{"original" => true}
    })
  end

  defp state(era) do
    %{
      State.new(%{
        client_info: %{"name" => "ResultRouterTest"},
        capabilities: %{},
        protocol_version: if(era == :modern, do: "2026-07-28", else: "2025-06-18"),
        transport: %{layer: MockTransport, name: MockTransport},
        timeout: 1_000
      })
      | era: era,
        negotiated_version: if(era == :modern, do: "2026-07-28", else: "2025-06-18")
    }
  end
end
