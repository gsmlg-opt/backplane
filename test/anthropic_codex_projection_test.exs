ExUnit.start()

defmodule Backplane.AnthropicCodexProjectionTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Codex.{Contract, MultiAgent, Tools}
  alias Backplane.AiProtocol.{Codec, Request}
  alias Backplane.AiProtocol.Codec.Anthropic

  # Only supplies declaration defaults. No child agent or tool is executed.
  defmodule DeclarationDefaults do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(_), do: {:ok, nil}

    def handle_call(:wait_options, _, state),
      do:
        {:reply,
         %{
           default_wait_timeout_ms: 30_000,
           min_wait_timeout_ms: 1,
           max_wait_timeout_ms: 3_600_000
         }, state}
  end

  test "exported Codex local and collaboration profile declarations round-trip through Anthropic" do
    runtime = start_supervised!(DeclarationDefaults)

    collaboration =
      for attrs <- MultiAgent.contracts(:v2, runtime) do
        {:ok, contract} = Contract.new(attrs)
        Contract.provider_definition(contract)
      end

    definitions = Tools.definitions() ++ collaboration

    tools =
      Enum.map(definitions, fn definition ->
        %{
          name: definition.name,
          description: definition.description,
          input_kind: if(definition.type == "custom", do: :custom, else: :function),
          input_schema: definition[:parameters],
          format: definition[:format],
          extensions:
            if(definition[:output_schema],
              do: %{"codex::output_schema" => definition.output_schema},
              else: %{}
            )
        }
      end)

    assert Enum.any?(tools, &(&1.input_kind == :custom))
    assert Enum.any?(tools, &String.contains?(&1.name, "::"))
    {:ok, request} = Request.new(%{model: "claude-test", input: [], tools: tools})
    assert {:ok, %{body: body, codec_options: opts}} = Anthropic.prepare_request(request)
    originals = Enum.zip(request.tools, body["tools"])
    raw = " \t*** Begin Patch\r\n+你好\n*** End Patch\r\n "

    calls =
      Enum.with_index(originals, fn {tool, projected}, index ->
        %{
          "type" => "tool_use",
          "id" => "call-#{index}",
          "name" => projected["name"],
          "input" => if(tool.input_kind == :custom, do: %{"input" => raw}, else: %{})
        }
      end)

    assert {:ok, response} =
             Codec.decode_response(
               :anthropic,
               200,
               [],
               %{"content" => calls, "stop_reason" => "tool_use"},
               opts
             )

    assert Enum.map(response.output, & &1.tool_call.name) == Enum.map(request.tools, & &1.name)

    for {tool, block} <- Enum.zip(request.tools, response.output), tool.input_kind == :custom do
      assert block.tool_call.raw_arguments == {:custom, raw}
    end

    results =
      Enum.map(response.output, fn block ->
        %{role: :tool, tool_call_id: block.tool_call.id, content: [%{type: :text, text: "ok"}]}
      end)

    {:ok, replay} =
      Request.new(%{
        model: "claude-test",
        tools: tools,
        input: [%{role: :assistant, content: response.output} | results]
      })

    assert {:ok, replay_body} = Codec.encode_request(:anthropic, replay, opts)
    assert hd(replay_body["messages"])["content"] == calls
    assert length(replay_body["messages"]) == length(calls) + 1
  end
end
