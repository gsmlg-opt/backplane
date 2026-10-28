Code.require_file("staged_export_file_host.exs", __DIR__)

defmodule Backplane.AgentRuntime.HeadlessColdBeamFixture do
  import ExUnit.Assertions

  alias Backplane.AgentRuntime.{Codex, Error}
  alias Backplane.AgentRuntime.Codex.{Headless, Session}
  alias Backplane.AgentRuntime.StagedExportFileHostFixture, as: FileHost

  defmodule Marker do
    def execute(operation) do
      context = operation.backend_context
      File.write!(context.marker, "effect\n", [:append])

      if context.lose_ack,
        do: :ok = FileHost.fault_next(context.store, "run.tool_completed", :lose_ack)

      {:ok, operation.arguments}
    end
  end

  def run("producer", root) do
    for label <- ["terminal", "ack-loss"] do
      dir = Path.join(root, label)
      {:ok, store} = FileHost.open(dir)
      {opts, session} = options(store, dir, label)
      {:ok, owner} = Headless.start_link(opts)

      input = %{
        "label" => "cold-input",
        "payload" => %{"answer" => 42, "flags" => [true, nil, "λ"]}
      }

      source = """
      // @exec: {"yield_time_ms": 1}
      text(input.label);
      yield 'generator';
      const effect = await tools.marker({payload: input.payload});
      await new Promise(resolve => setTimeout(resolve, 30));
      text('after');
      return {input, effect};
      """

      assert {:ok, identity} = Headless.execute(owner, source, input: input)
      assert identity.run_id == "headless-cold-" <> label

      expected = %{
        status: :completed,
        value: %{"input" => input, "effect" => %{"payload" => input["payload"]}},
        output: [
          %{"type" => "text", "text" => "cold-input"},
          %{"type" => "text", "text" => "after"}
        ],
        output_truncated: false,
        nested_invocations: 1,
        outer_reservations: 1
      }

      if label == "terminal" do
        assert {:ok, ^expected} = Headless.await(owner, timeout: 5_000)
      else
        assert {:error, %Error{class: :unknown_outcome}} = Headless.await(owner, timeout: 5_000)
        assert Headless.status(owner).phase == :storage_failed
      end

      assert {:ok, record} = FileHost.load(store, identity.run_id)
      assert map_size(Map.get(record.run, :provider_attempts, %{})) == 0
      refute Enum.any?(record.journal, &(elem(&1.command, 0) == :provider_started))
      assert Enum.count(record.journal, &(elem(&1.command, 0) == :host_step_started)) == 1
      assert File.read!(Path.join(dir, "effects")) == "effect\n"

      if label == "terminal" do
        assert record.run.state == :completed
        assert record.run.context.conversation.headless_result == expected
        assert map_size(record.run.tool_results) == 2
      else
        assert record.run.state == :running
        assert map_size(record.run.tool_results) == 1
        [result] = Map.values(record.run.tool_results)
        assert result["payload"] == input["payload"]
      end

      assert :ok =
               FileHost.put(store, :source, %{
                 producer_os_pid: System.pid(),
                 run_id: identity.run_id,
                 expected: expected,
                 record: record
               })

      GenServer.stop(owner)
      GenServer.stop(session)
      FileHost.cleanup(store)
    end

    IO.puts(
      JSON.encode!(%{
        producer_os_pid: System.pid(),
        provider_attempts: 0,
        effects: 2,
        terminal: 1,
        nonterminal: 1
      })
    )
  end

  def run("consumer", root) do
    for label <- ["terminal", "ack-loss"] do
      dir = Path.join(root, label)
      {:ok, store} = FileHost.open(dir)
      assert {:ok, source} = FileHost.get(store, :source)
      refute source.producer_os_pid == System.pid()
      assert {:ok, original} = FileHost.load(store, source.run_id)
      assert original == source.record
      before = File.read!(Path.join(dir, "host.term"))

      {:ok, owner} =
        Headless.start_link(
          run_id: source.run_id,
          incarnation: original.run.incarnation,
          run: original.run,
          store: FileHost,
          context: store
        )

      if label == "terminal" do
        assert Headless.status(owner).phase == :terminal
        assert {:ok, result} = Headless.await(owner, timeout: 0)
        assert result == source.expected
      else
        assert Headless.status(owner).phase == :recovery_required
        assert {:error, %Error{class: :unknown_outcome}} = Headless.await(owner, timeout: 0)
      end

      assert {:error, %Error{class: :resource_conflict}} = Headless.execute(owner, "return 99;")
      assert {:ok, ^original} = FileHost.load(store, source.run_id)
      assert File.read!(Path.join(dir, "host.term")) == before
      assert File.read!(Path.join(dir, "effects")) == "effect\n"
      GenServer.stop(owner)
      FileHost.cleanup(store)
    end

    IO.puts(
      JSON.encode!(%{
        consumer_os_pid: System.pid(),
        provider_attempts: 0,
        effects: 2,
        terminal_inspections: 1,
        recovery_required: 1,
        replays: 0
      })
    )
  end

  defp options(store, dir, label) do
    run_id = "headless-cold-" <> label
    {:ok, session} = Session.start_link(owner_pid: self())

    authority = %{
      caller: "cold-host",
      run_id: run_id,
      grants: ["exec", "wait", "marker"],
      tool_revision: 1
    }

    {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    contract = %{
      name: "marker",
      description: "one real file effect",
      schema: %{
        "type" => "object",
        "properties" => %{"payload" => %{"type" => "object"}},
        "required" => ["payload"],
        "additionalProperties" => false
      },
      backend: Marker,
      backend_context: %{
        marker: Path.join(dir, "effects"),
        store: store,
        lose_ack: label == "ack-loss"
      },
      revision: 1,
      strict: true,
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    {:ok, profile} =
      Codex.profile(
        :mixed,
        %{session_binding: binding, code_mode_contracts: [contract], timeout: 5_000},
        authority,
        tools: ["exec", "wait", "marker"]
      )

    {[
       run_id: run_id,
       incarnation: 1,
       session_binding: binding,
       registry: profile.registry,
       tools: profile.tools,
       authority: profile.authority,
       store: FileHost,
       context: store,
       run_timeout: 10_000,
       effect_timeout: 8_000
     ], session}
  end
end

[mode, root] = System.argv()
Backplane.AgentRuntime.HeadlessColdBeamFixture.run(mode, root)
