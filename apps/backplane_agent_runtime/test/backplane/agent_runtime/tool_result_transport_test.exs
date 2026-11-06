defmodule Backplane.AgentRuntime.ToolResultTransportTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}
  alias Backplane.AgentRuntime.{Error, ToolResultContract}

  test "JSON escaping is charged independently and a consumed allowance never widens the next result" do
    assert is_binary(System.find_executable("deno"))
    registry = start_supervised!(ResourceRegistry)
    escaped = %{text: String.duplicate("\n", 100)}

    dispatcher = fn _, _ ->
      ToolResultContract.deliver({:ok, escaped}, %{
        schema_version: 1,
        output_limit: 1_000,
        json_limit: 150
      })
    end

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.execute(registry, "escaped", "return await codex.tool('image', {});",
               dispatcher: dispatcher
             )

    payload = %{text: String.duplicate("A", 1_100_000)}
    test = self()

    dispatcher = fn request, _ ->
      send(test, {:called, request.tool_name})

      case request.tool_name do
        "selected" ->
          ToolResultContract.deliver({:ok, payload}, %{
            schema_version: 1,
            output_limit: 1_200_000,
            json_limit: 1_200_000
          })

        "ordinary" ->
          {:ok, payload}
      end
    end

    source = """
    const first = await codex.tool('selected', {});
    if (first.text.length !== 1100000) throw new Error('content mismatch');
    await codex.tool('ordinary', {});
    return 'unreachable';
    """

    assert {:error, %Error{class: :budget_exceeded}} =
             CodeMode.execute(registry, "reset", source, dispatcher: dispatcher)

    assert_receive {:called, "selected"}
    assert_receive {:called, "ordinary"}
  end
end
