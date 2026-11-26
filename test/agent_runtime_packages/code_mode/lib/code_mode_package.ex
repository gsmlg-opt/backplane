defmodule CodeModePackage do
  @moduledoc false
  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry}

  def verify! do
    executable = System.fetch_env!("BACKPLANE_CODE_MODE_RUNNER")
    true = Path.type(executable) == :absolute
    true = File.regular?(executable)
    original_path = System.get_env("PATH")
    kill = System.find_executable("kill") || raise "OS lifecycle kill helper is unavailable"
    ps = System.find_executable("ps")

    for name <- ["SECRET_KEY_BASE", "DATABASE_URL", "BACKPLANE_CONFIG", "PHX_SERVER"],
        do: System.delete_env(name)

    host_path = Path.join(File.cwd!(), "lifecycle-path-#{System.unique_integer([:positive])}")
    File.mkdir!(host_path)
    File.ln_s!(kill, Path.join(host_path, "kill"))
    System.put_env("PATH", host_path)

    try do
      for tool <- ["deno", "elixir", "mix"], do: nil = System.find_executable(tool)
      :verified = CodeMode.lifecycle_capability(%{code_mode_runner: executable})
      {:ok, registry} = ResourceRegistry.start_link([])

      try do
        opts = [
          code_mode_runner: executable,
          dispatcher: fn %{tool_name: "echo", arguments: %{"value" => value}}, _ ->
            {:ok, value}
          end,
          timeout: 10_000,
          yield_time_ms: 1_000
        ]

        source = """
        text('before');
        store('count', 1);
        yield 'paused';
        text(await codex.tool('echo', {value: load('count') + 1}));
        return 42;
        """

        started = System.monotonic_time(:millisecond)

        {:ok, %{status: :yielded, handle: first, output: [%{"text" => "before"}]}} =
          CodeMode.execute(registry, "root", source, opts)

        root_startup = System.monotonic_time(:millisecond) - started

        # Each retained cell owns an independent OS process, sharing the artifact.
        started = System.monotonic_time(:millisecond)

        {:ok, %{status: :yielded, handle: second}} =
          CodeMode.execute(registry, "child", "yield 'paused'; return 7;", opts)

        child_startup = System.monotonic_time(:millisecond) - started

        first_pid = process_id!(registry, first, "root")
        second_pid = process_id!(registry, second, "child")
        true = first_pid != second_pid

        IO.puts(
          "Runner sample: execute-to-first-yield ms root=#{root_startup} child=#{child_startup}; " <>
            "RSS KiB root=#{rss(ps, first_pid)} child=#{rss(ps, second_pid)}"
        )

        {:ok, %{status: :completed, value: 42, output: [%{"text" => "2"}]}} =
          CodeMode.resume(registry, first, nil, owner: "root", yield_time_ms: 1_000)

        {:ok, %{status: :completed, value: 7}} =
          CodeMode.resume(registry, second, nil, owner: "child", yield_time_ms: 1_000)

        # Environment selection is the consumer-facing alternative to an option.
        {:ok, %{status: :completed, value: 3}} =
          CodeMode.execute(
            registry,
            "environment",
            "return 1 + 2;",
            Keyword.delete(opts, :code_mode_runner)
          )

        for {app, _, _} <- Application.started_applications() do
          false = app in [:backplane, :backplane_api, :backplane_admin, :backplane_system, :ecto]
        end

        IO.puts(
          "Code Mode independent runner package: PASS (distinct OS identities, empty runner PATH)"
        )
      after
        GenServer.stop(registry)
      end
    after
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
      File.rm_rf!(host_path)
    end
  end

  defp process_id!(registry, handle, owner) do
    {:ok, worker} = ResourceRegistry.fetch(registry, handle, owner)
    {:os_pid, pid} = worker |> :sys.get_state() |> Map.fetch!(:port) |> Port.info(:os_pid)
    pid
  end

  defp rss(nil, _pid), do: "unavailable"

  defp rss(ps, pid) do
    case System.cmd(ps, ["-o", "rss=", "-p", Integer.to_string(pid)]) do
      {value, 0} -> String.trim(value)
      _ -> "unavailable"
    end
  end
end
