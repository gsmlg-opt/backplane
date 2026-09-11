defmodule Backplane.SkillProtocol.CacheSourceTest do
  use ExUnit.Case, async: true

  import Backplane.SkillProtocol.ArchiveHelpers

  alias Backplane.SkillProtocol.{Bundle, Cache, Client, Error, Resource, SkillRef, Wire}
  alias Backplane.SkillProtocol.Source.Backplane, as: BackplaneSource

  @moduletag :tmp_dir

  test "online source prepares an exact bundle and later permits explicit age-bounded offline reuse",
       %{
         tmp_dir: tmp_dir
       } do
    {manifest, bytes} = bundle_fixture(tmp_dir)
    cache = cache(tmp_dir)

    source =
      source(client(sequence([manifest_response(manifest), artifact_response(bytes)])), cache)

    assert {:ok, prepared} = BackplaneSource.prepare(source, "opaque/id", "r1")
    assert {:ok, "guide"} = Resource.read(prepared, "references/guide.md")

    offline = source(client(fn _ -> {:error, :econnrefused} end), cache)
    assert {:ok, reused} = BackplaneSource.prepare(offline, "opaque/id", "r1")
    assert reused.root == prepared.root

    disabled = %{offline | offline_policy: :disabled}

    assert {:error, %Error{code: :temporarily_unavailable}} =
             BackplaneSource.prepare(disabled, "opaque/id", "r1")

    assert {:error, %Error{code: :temporarily_unavailable}} =
             BackplaneSource.prepare(offline, "opaque/id", nil)
  end

  test "offline association is isolated by source and access context and expires", %{
    tmp_dir: tmp_dir
  } do
    {:ok, now} = Agent.start_link(fn -> 100 end)
    clock = fn -> Agent.get(now, & &1) end
    {manifest, bytes} = bundle_fixture(tmp_dir)
    cache = cache(tmp_dir, clock: clock)

    online =
      source(
        client(sequence([manifest_response(manifest), artifact_response(bytes)]),
          credential_supplier: fn -> "ultra-secret" end
        ),
        cache
      )

    assert {:ok, _prepared} = BackplaneSource.prepare(online, "opaque/id", "r1")

    isolated_clients = [
      client(fn _ -> {:error, :offline} end, access_context_id: "tenant-b"),
      client(fn _ -> {:error, :offline} end, source_id: "source-b")
    ]

    for isolated_client <- isolated_clients do
      wrong_scope = source(isolated_client, cache)

      assert {:error, %Error{code: :temporarily_unavailable}} =
               BackplaneSource.prepare(wrong_scope, "opaque/id", "r1")
    end

    cache.root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.each(fn path -> refute String.contains?(File.read!(path), "ultra-secret") end)

    Agent.update(now, fn _ -> 2_000 end)

    expired =
      source(client(fn _ -> {:error, :offline} end), cache, offline_policy: {:age_bounded, 500})

    assert {:error, %Error{code: :temporarily_unavailable}} =
             BackplaneSource.prepare(expired, "opaque/id", "r1")
  end

  test "known denial persists across restart and blocks fallback until successful revalidation",
       %{
         tmp_dir: tmp_dir
       } do
    {manifest, bytes} = bundle_fixture(tmp_dir)
    cache = cache(tmp_dir)

    online =
      source(client(sequence([manifest_response(manifest), artifact_response(bytes)])), cache)

    assert {:ok, _prepared} = BackplaneSource.prepare(online, "opaque/id", "r1")

    denied =
      source(
        client(fn _ -> {:ok, %{status: 403, headers: %{}, body: error_json("forbidden")}} end),
        cache
      )

    assert {:error, %Error{code: :forbidden}} = BackplaneSource.prepare(denied, "opaque/id", "r1")

    restarted_cache = cache(tmp_dir)
    offline = source(client(fn _ -> {:error, :offline} end), restarted_cache)

    assert {:error, %Error{code: :forbidden}} =
             BackplaneSource.prepare(offline, "opaque/id", "r1")

    revalidated =
      source(
        client(sequence([manifest_response(manifest), artifact_response(bytes)])),
        restarted_cache
      )

    assert {:ok, _prepared} = BackplaneSource.prepare(revalidated, "opaque/id", "r1")
    assert {:ok, _prepared} = BackplaneSource.prepare(offline, "opaque/id", "r1")
  end

  test "corruption is detected after restart and remains a known integrity failure", %{
    tmp_dir: tmp_dir
  } do
    {manifest, bytes} = bundle_fixture(tmp_dir)
    cache = cache(tmp_dir)

    online =
      source(client(sequence([manifest_response(manifest), artifact_response(bytes)])), cache)

    assert {:ok, prepared} = BackplaneSource.prepare(online, "opaque/id", "r1")

    File.write!(Path.join(prepared.root, "references/guide.md"), "corrupt")
    restarted = cache(tmp_dir)
    offline = source(client(fn _ -> {:error, :offline} end), restarted)

    assert {:error, %Error{code: :integrity_mismatch}} =
             BackplaneSource.prepare(offline, "opaque/id", "r1")

    File.write!(Path.join(prepared.root, "references/guide.md"), "guide")

    assert {:error, %Error{code: :integrity_mismatch}} =
             BackplaneSource.prepare(offline, "opaque/id", "r1")
  end

  test "concurrent prepare converges on one complete installation", %{tmp_dir: tmp_dir} do
    {manifest, bytes} = bundle_fixture(tmp_dir)
    cache = cache(tmp_dir)

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          Cache.install(cache, client(fn _ -> flunk("unused") end), manifest, bytes)
        end)
      end

    roots = for task <- tasks, {:ok, prepared} = Task.await(task), do: prepared.root
    assert [root] = Enum.uniq(roots)
    assert File.read!(Path.join(root, "references/guide.md")) == "guide"
  end

  test "cancellation and capacity failure expose no partial association or prepared root", %{
    tmp_dir: tmp_dir
  } do
    {manifest, bytes} = bundle_fixture(tmp_dir)
    client = client(fn _ -> flunk("unused") end)
    cancelled = cache(tmp_dir, cancelled?: fn -> true end)

    assert {:error, %Error{code: :cancelled}} = Cache.install(cancelled, client, manifest, bytes)
    assert [] == Path.wildcard(Path.join([cancelled.root, "prepared", "*"]))
    assert [] == Path.wildcard(Path.join([cancelled.root, "associations", "*"]))

    too_small = cache(Path.join(tmp_dir, "small"), max_bytes: byte_size(bytes) - 1)

    assert {:error, %Error{code: :capacity_exceeded}} =
             Cache.install(too_small, client, manifest, bytes)

    assert [] == Path.wildcard(Path.join([too_small.root, "prepared", "*"]))
  end

  test "association persistence failure rolls back only the attempted installation", %{
    tmp_dir: tmp_dir
  } do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :skill_protocol, :operation],
        fn event, measurements, metadata, owner ->
          send(owner, {:cache_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {manifest, bytes} = bundle_fixture(tmp_dir)
    cache = cache(tmp_dir)
    client = client(fn _ -> flunk("unused") end)
    assert {:ok, existing} = Cache.install(cache, client, manifest, bytes)

    assert_receive {:cache_telemetry, [:backplane, :skill_protocol, :operation],
                    %{artifact_bytes: artifact_bytes, duration_ms: duration},
                    %{
                      phase: :cache,
                      operation: :install,
                      outcome: :ok,
                      cache_outcome: :installed,
                      source_id: "source-a",
                      skill_id: "opaque/id",
                      revision: "r1"
                    } = installed_metadata}

    assert artifact_bytes == byte_size(bytes)
    assert duration >= 0
    refute inspect(installed_metadata) =~ cache.root

    artifacts_before = Path.wildcard(Path.join([cache.root, "artifacts", "*"]))
    prepared_before = Path.wildcard(Path.join([cache.root, "prepared", "*"]))
    associations = Path.join(cache.root, "associations")
    saved_associations = Path.join(cache.root, "associations.saved")
    File.rename!(associations, saved_associations)
    File.write!(associations, "forces deterministic enotdir")

    attempted = %{
      manifest
      | ref: %{manifest.ref | revision: "r2"}
    }

    assert {:error, %Error{code: :invalid_request}} =
             Cache.install(cache, client, attempted, bytes)

    assert_receive {:cache_telemetry, [:backplane, :skill_protocol, :operation], _measurements,
                    %{
                      phase: :cache,
                      operation: :install,
                      outcome: :error,
                      error_code: :invalid_request,
                      cache_outcome: :error,
                      revision: "r2"
                    }}

    assert artifacts_before == Path.wildcard(Path.join([cache.root, "artifacts", "*"]))
    assert prepared_before == Path.wildcard(Path.join([cache.root, "prepared", "*"]))
    assert [] == Path.wildcard(Path.join([cache.root, ".staging", "*"]))

    File.rm!(associations)
    File.rename!(saved_associations, associations)

    assert {:ok, reused} = Cache.install(cache, client, manifest, bytes)
    assert reused.root == existing.root
    assert {:ok, "guide"} = Resource.read(reused, "references/guide.md")

    assert_receive {:cache_telemetry, [:backplane, :skill_protocol, :operation], _measurements,
                    %{
                      phase: :cache,
                      operation: :install,
                      outcome: :ok,
                      cache_outcome: :hit,
                      revision: "r1"
                    }}
  end

  test "cleanup removes only staging and active prepared resources survive", %{tmp_dir: tmp_dir} do
    {manifest, bytes} = bundle_fixture(tmp_dir)
    cache = cache(tmp_dir)
    client = client(fn _ -> flunk("unused") end)
    assert {:ok, prepared} = Cache.install(cache, client, manifest, bytes)

    stale = Path.join([cache.root, ".staging", "stale"])
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "partial"), "partial")
    assert :ok = Cache.cleanup(cache)
    refute File.exists?(stale)
    assert {:ok, "guide"} = Resource.read(prepared, "references/guide.md")
  end

  test "cache roots enforce explicit ownership", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "owned")
    assert {:ok, _cache} = Cache.new(root, owner: "consumer-a")
    assert {:ok, _same_process_cache} = Cache.new(root, owner: "consumer-a")

    assert {:error, %Error{code: :invalid_request}} =
             Cache.new(root, owner: "consumer-b")
  end

  test "cache root excludes another OS process and recovers its crashed claim", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "cross-process")
    port = start_cache_owner(root, "shared-owner")
    on_exit(fn -> stop_cache_owner(port) end)

    assert :ready = await_cache_owner(port)

    assert {:error,
            %Error{code: :invalid_request, message: "cache root is owned by another OS process"}} =
             Cache.new(root, owner: "shared-owner")

    stop_cache_owner(port)
    assert_receive {^port, {:exit_status, _status}}, 5_000

    assert {:ok, _recovered} = Cache.new(root, owner: "shared-owner")
  end

  defp bundle_fixture(tmp_dir) do
    archive =
      archive!(
        tmp_dir,
        [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/references/guide.md", "guide"}
        ],
        "remote.tar.gz"
      )

    bytes = File.read!(archive)
    ref = %SkillRef{source_id: "source-a", skill_id: "opaque/id", revision: "r1"}
    assert {:ok, bundle} = Bundle.inspect(archive, ref: ref)
    {bundle.manifest, bytes}
  end

  defp cache(tmp_dir, opts \\ []) do
    Cache.new!(Path.join(tmp_dir, "cache"), Keyword.merge([owner: "test-consumer"], opts))
  end

  defp client(transport, opts \\ []) do
    Client.new!(
      Keyword.merge(
        [
          endpoint: "https://backplane.example",
          source_id: "source-a",
          access_context_id: "tenant-a",
          credential_supplier: fn -> nil end,
          retry_delays_ms: [0, 0],
          transport: transport
        ],
        opts
      )
    )
  end

  defp source(client, cache, opts \\ []) do
    BackplaneSource.new!(
      client,
      cache,
      Keyword.merge([offline_policy: {:age_bounded, 1_000}], opts)
    )
  end

  defp manifest_response(manifest),
    do: {:ok, %{status: 200, headers: %{}, body: JSON.encode!(Wire.manifest_map(manifest))}}

  defp artifact_response(bytes), do: {:ok, %{status: 200, headers: %{}, body: bytes}}

  defp error_json(code) do
    JSON.encode!(%{
      "protocol_version" => "1",
      "error" => %{"code" => code, "message" => code, "retryable" => false, "context" => %{}}
    })
  end

  defp sequence(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    fn _request ->
      Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)
    end
  end

  defp start_cache_owner(root, owner) do
    elixir = System.find_executable("elixir") || flunk("elixir executable is unavailable")
    ebin = :backplane_skill_protocol |> :code.lib_dir() |> Path.join("ebin")

    expression = """
    {:ok, _coordinator} = Backplane.SkillProtocol.Cache.Ownership.start_link([])
    root = hd(System.argv())
    owner = System.argv() |> tl() |> hd()

    case Backplane.SkillProtocol.Cache.new(root, owner: owner) do
      {:ok, _cache} ->
        IO.puts("CACHE_OWNER_READY")
        Process.sleep(:infinity)

      {:error, error} ->
        IO.puts("CACHE_OWNER_ERROR:" <> inspect(error))
    end
    """

    Port.open(
      {:spawn_executable, elixir},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-pa", ebin, "-e", expression, "--", root, owner]
      ]
    )
  end

  defp await_cache_owner(port, output \\ "") do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        if output =~ "CACHE_OWNER_READY" do
          :ready
        else
          await_cache_owner(port, output)
        end

      {^port, {:exit_status, status}} ->
        flunk("cache owner exited with status #{status}: #{output}")
    after
      5_000 -> flunk("cache owner did not become ready: #{output}")
    end
  end

  defp stop_cache_owner(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        executable = System.find_executable("kill") || flunk("kill executable is unavailable")
        {_output, 0} = System.cmd(executable, ["-KILL", Integer.to_string(pid)])
        :ok

      nil ->
        :ok
    end
  end
end
