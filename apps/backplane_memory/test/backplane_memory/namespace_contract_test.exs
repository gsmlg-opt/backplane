defmodule BackplaneMemory.NamespaceContractTest do
  use ExUnit.Case, async: false

  alias Backplane.Registry.ToolRegistry
  alias BackplaneMemory.Service

  @memory_api [
    count: 0,
    count: 1,
    forget: 1,
    get: 1,
    list: 0,
    list: 1,
    maybe_detect_contradiction: 2,
    remember: 1,
    remember: 2,
    scope_stats: 0,
    stats: 0,
    team_feed: 1,
    team_feed: 2,
    team_share: 2
  ]

  @observation_api [
    end_session: 1,
    file_history: 1,
    file_history: 2,
    record: 2,
    record: 3,
    register_session: 2
  ]

  # Fingerprints keep the complete schemas visible as a compact, exact contract.
  # Any key, value, default, enum, description, or required-field change alters the digest.
  @core_tool_contracts [
    {"memory::facet_tag", "f02c5459fb417d4a86cb121b650dbcbf42d41f6b1ded88d56b1ea02cf54cc9d5"},
    {"memory::facet_query", "b9873017618d35e7063f7b8143c27d09711f8ff657482022d59356554a74c122"},
    {"memory::remember", "ad77b2c97bfd25238cba2d8a51e87309a773ff94b7ce86b83d4619d352d8cd47"},
    {"memory::recall", "e1228a017dae05eb8c1a8410401b654f65238e3a609d5360ba169a3bcfa73717"},
    {"memory::list", "945afe0e1110224a03edc03b8ba1c9244bda95835733f893ee6f55c3c6f180d3"},
    {"memory::forget", "141f64d3f41b18db870a320c78edd80755d43ffed764f4661b64bf7421a9f92e"},
    {"memory::stats", "cadd96657217a7d93bedd0056277d9afb9af80fdcf4890d57aa9dfdec778e09c"},
    {"memory::profile", "72a1e29bdbf4ee2495ed7658dd202bc29dbb1c5ccf29f6c572febb9cac8bcfdc"},
    {"memory::profile_refresh",
     "18faf46daff0de4c65fae4863343f973908f15bb1f96183e79fd7d29e09a4589"},
    {"memory::expand_query", "09aefc5c14c4587095fef5c496a390fb4ee344399a097b79f68a1490f99011ac"},
    {"memory::file_history", "b48685df6b1844bdb12b7ff1736c94215133a486884f65ba8ff77e2a8f9d3b83"},
    {"memory::team_share", "1f710b769fcabce2aec35a00d9a6a6f3788f89b8766823ea6855b1dc1406b758"},
    {"memory::team_feed", "c23507bb19c0ad476dea0ff9b9151057b2f41187086052f2ace5889502a91268"},
    {"memory::lease", "6da7388dc90c01a5d6c3eec4a2819689e5a0df16778e7fc79aa35d54fd36fbbf"},
    {"memory::signal_send", "00f60264fecf10967762ab9860a432d0536f5c09c06b85986308cc5612a291ba"},
    {"memory::signal_read", "bb2cc9ace1ff5f8803ec11d86cac069cfaa8f61186a547ba7791554c0320d687"},
    {"memory::action_create", "3f8511fc69884e9107a754902ba0e9a90b5e031396c8423b1f406c4d98e101bf"},
    {"memory::action_update", "994218489f92b716fa1cea02361f63ad38c7d7e772d08bb20561fe9ec9e164e5"},
    {"memory::frontier", "129a9f4e82812211418fcbd8422f0b3ebadf62a07870f544f07285677604dd7a"},
    {"memory::next", "129a9f4e82812211418fcbd8422f0b3ebadf62a07870f544f07285677604dd7a"},
    {"memory::smart_search", "526b71d1976aeb512377a66ade3bca87a018fb42812f753bfe33315daf9cd390"},
    {"memory::sessions", "b7170d5002781654078d1cd2e51b08037d83bc214baee04c83e867f77d0bcd7c"},
    {"memory::patterns", "3b78b3b84cadbb68492387b72d298bed77c9ebb3fad130bbbf49d4d496c8d7bd"},
    {"memory::timeline", "79f886137bdf04c8beaa0a5a5e791008890862d8a8a353f3d7f69dbabc8505f8"},
    {"memory::export", "0d1ce286ba0cd50f348681dc087e3d973a073a4b7ee764974760974b794ecb88"},
    {"memory::relations", "0910a6da3840d37c4eaee6cc9d0d5fd6a1d8b9b05cef0141ba157a7e2beeda40"},
    {"memory::compress_file", "bb0abc766d39c2a56989d18303623a05e6241e6e1c5701dc0a55f53daaed22a6"},
    {"memory::audit", "dca7422220d538500eb01c1fa7ffe32bcc16f49cfcd21ef80c443b39ccbf852a"},
    {"memory::governance_delete",
     "6e12021a792c4d7ca09e85292ac21cea9a2a5a026ca7baf0754865019ae69805"},
    {"memory::diagnose", "cadd96657217a7d93bedd0056277d9afb9af80fdcf4890d57aa9dfdec778e09c"},
    {"memory::heal", "cadd96657217a7d93bedd0056277d9afb9af80fdcf4890d57aa9dfdec778e09c"}
  ]

  @extended_tool_contracts [
    {"memory::graph_query", "b1ace1ac519d644e661b4d0629763c5d67feab7ed4ec7af9735f29bfc74fed4f"},
    {"memory::graph_stats", "cadd96657217a7d93bedd0056277d9afb9af80fdcf4890d57aa9dfdec778e09c"},
    {"memory::consolidate", "52c5e8ee28186a06e64534fc134167cae42e42b500af64cd44899c7bee7ff09d"},
    {"memory::verify", "c37839c4060e4d6590ba406b2f498ae4c267fee2f17d0453d6945a2398210887"},
    {"memory::slot_read", "7acca181803e00a1c2169361303c9ba069bc6e2927cf63158a13d0f8b34ca4cc"},
    {"memory::slot_write", "83f4215892b7f1e03898d1008bfeebf81323b494282e7db2ae08b9793bfff417"},
    {"memory::slot_list", "cadd96657217a7d93bedd0056277d9afb9af80fdcf4890d57aa9dfdec778e09c"},
    {"memory::enrich", "14df6a9949b3742e6a29f1e0ca747927a9ccf3612888d42052aa99bf2fe79f8f"},
    {"memory::access_log", "c37839c4060e4d6590ba406b2f498ae4c267fee2f17d0453d6945a2398210887"}
  ]

  @full_tool_contracts @core_tool_contracts ++ @extended_tool_contracts

  @worker_options [
    {BackplaneMemory.Workers.AccessWritebackWorker, memory: 3},
    {BackplaneMemory.Workers.EmbedWorker, memory: 5},
    {BackplaneMemory.Workers.EpisodicWorker, memory: 3},
    {BackplaneMemory.Workers.EvictionWorker, memory: 3},
    {BackplaneMemory.Workers.FallbackSweepWorker, memory: 2},
    {BackplaneMemory.Workers.GraphExtractWorker, memory: 3},
    {BackplaneMemory.Workers.LeaseCleanupWorker, memory: 3},
    {BackplaneMemory.Workers.ProceduralWorker, memory: 2},
    {BackplaneMemory.Workers.ProfileBuildWorker, memory: 3},
    {BackplaneMemory.Workers.SummaryWorker, memory: 3}
  ]

  describe "public namespace compatibility" do
    test "BackplaneMemory exposes version/0 with its current value" do
      assert BackplaneMemory.__info__(:functions) == [version: 0]
      assert BackplaneMemory.version() == "0.1.0"
    end

    test "Memory exposes the supported function arities" do
      assert BackplaneMemory.Memory.__info__(:functions) == @memory_api
    end

    test "Observations exposes the supported function arities" do
      assert BackplaneMemory.Observations.__info__(:functions) == @observation_api
    end
  end

  describe "managed service compatibility" do
    test "uses the memory prefix and is enabled only by boolean true" do
      saved_setting = preserve_ets_key(:backplane_settings, "services.memory.enabled")

      on_exit(fn ->
        restore_ets_key(:backplane_settings, "services.memory.enabled", saved_setting)
      end)

      assert Service.prefix() == "memory"

      for disabled <- [nil, false, "true", 1] do
        put_ets_setting("services.memory.enabled", disabled)
        refute Service.enabled?()
      end

      put_ets_setting("services.memory.enabled", true)
      assert Service.enabled?()
    end

    test "exposes exactly 31 default tool names and schemas" do
      saved_setting = preserve_ets_key(:backplane_settings, "memory.tools")
      on_exit(fn -> restore_ets_key(:backplane_settings, "memory.tools", saved_setting) end)
      :ets.delete(:backplane_settings, "memory.tools")

      assert tool_contract(Service.tools()) == @core_tool_contracts
    end

    test "exposes exactly 40 full tool names and schemas" do
      saved_setting = preserve_ets_key(:backplane_settings, "memory.tools")
      on_exit(fn -> restore_ets_key(:backplane_settings, "memory.tools", saved_setting) end)
      :ets.insert(:backplane_settings, {"memory.tools", "all"})

      assert tool_contract(Service.tools()) == @full_tool_contracts
    end

    test "application start registers every default memory tool when enabled" do
      registry_snapshot = :ets.tab2list(:backplane_tools)
      enabled_snapshot = preserve_ets_key(:backplane_settings, "services.memory.enabled")
      tools_snapshot = preserve_ets_key(:backplane_settings, "memory.tools")
      was_started? = application_started?(:backplane_memory)

      on_exit(fn ->
        _ = Application.stop(:backplane_memory)
        restore_ets_key(:backplane_settings, "services.memory.enabled", enabled_snapshot)
        restore_ets_key(:backplane_settings, "memory.tools", tools_snapshot)

        if was_started? do
          {:ok, _} = Application.ensure_all_started(:backplane_memory)
        end

        :ets.delete_all_objects(:backplane_tools)
        :ets.insert(:backplane_tools, registry_snapshot)
      end)

      :ok = Application.stop(:backplane_memory)
      :ets.insert(:backplane_settings, {"services.memory.enabled", true})
      :ets.delete(:backplane_settings, "memory.tools")
      :ets.delete_all_objects(:backplane_tools)

      assert {:ok, _started} = Application.ensure_all_started(:backplane_memory)

      registered_tools =
        ToolRegistry.list_all()
        |> Enum.filter(&match?(%{origin: {:managed, "memory"}}, &1))

      assert tool_contract(registered_tools) == Enum.sort(@core_tool_contracts)
    end
  end

  test "workers retain their memory queue and max-attempt options" do
    for {worker, [{queue, max_attempts}]} <- @worker_options do
      assert Keyword.take(worker.__opts__(), [:queue, :max_attempts]) ==
               [queue: queue, max_attempts: max_attempts]
    end
  end

  defp tool_contract(tools) do
    Enum.map(tools, fn tool ->
      digest =
        tool.input_schema
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {tool.name, digest}
    end)
  end

  defp put_ets_setting(key, nil), do: :ets.delete(:backplane_settings, key)
  defp put_ets_setting(key, value), do: :ets.insert(:backplane_settings, {key, value})

  defp preserve_ets_key(table, key), do: :ets.lookup(table, key)

  defp restore_ets_key(table, key, saved_rows) do
    :ets.delete(table, key)

    if saved_rows != [] do
      :ets.insert(table, saved_rows)
    end
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {started, _description, _version} ->
      started == application
    end)
  end
end
