defmodule Backplane.Memory.NamespaceContractTest do
  use ExUnit.Case, async: false

  alias Backplane.Registry.{InputValidator, PromptRegistry, ToolRegistry}
  alias Backplane.Memory.Service

  @memories_api [
    count: 0,
    count: 1,
    count: 2,
    forget: 1,
    forget: 2,
    get: 1,
    get: 2,
    list: 0,
    list: 1,
    list: 2,
    list_evidence: 1,
    maybe_detect_contradiction: 2,
    provenance_trace: 1,
    record_application: 4,
    remember: 1,
    remember: 2,
    scope_stats: 0,
    stats: 0,
    team_feed: 1,
    team_feed: 2,
    team_feed: 3,
    team_share: 2,
    team_share: 3,
    trusted_count: 0,
    trusted_count: 1,
    trusted_forget: 1,
    trusted_get: 1,
    trusted_list: 0,
    trusted_list: 1,
    trusted_verify: 1,
    verify: 1,
    verify: 2
  ]

  @observation_api [
    end_session: 1,
    end_session: 2,
    file_history: 1,
    file_history: 2,
    record: 2,
    record: 3,
    register_session: 2,
    register_session: 3
  ]

  # Fingerprints keep the complete schemas visible as a compact, exact contract.
  # Any key, value, default, enum, description, or required-field change alters the digest.
  @core_tool_contracts [
    {"memory::activity_summary",
     "0b3809dcc7c10407f451f190c3745075a626efdd3c350dfa5a982e070acd88f0"},
    {"memory::recall_explain",
     "9964a85e2340b7e62cf28fb4f722e66b300e77d4bf5bd887536e2aaa2b9cab82"},
    {"memory::crystal_get", "9b6388dece3f7d051cf8f31f8e9e5b2019f9bb25573c92cd5147971e6ddb04d6"},
    {"memory::crystal_list", "c9784a879492c7dedf8b8b2b5ce2f0e43b9e97f93f4fe01305a8c7715767bf3f"},
    {"memory::crystal_search",
     "cb9443bba33b573518ed22c37defa1d4891d93e52268d370c1f4ac22020819ea"},
    {"memory::lesson_save", "7f2f2b48d24792d6c656038ed1cc6f3620d34afa9c28ac314ea2979d5d2a6eaa"},
    {"memory::lesson_recall", "32ba796e6454978950ca74317526499351b9c4f1a979b3e495dd77be1ab4afa9"},
    {"memory::apply", "a2cc1e206b4a87d2d1758a7b5a5f509851623b96e410b2908d1efa696ca7130f"},
    {"memory::facet_tag", "f02c5459fb417d4a86cb121b650dbcbf42d41f6b1ded88d56b1ea02cf54cc9d5"},
    {"memory::facet_query", "b9873017618d35e7063f7b8143c27d09711f8ff657482022d59356554a74c122"},
    {"memory::remember", "d9fa08ccb2377be72de08b7b1b3e2c24fe3e6769c39a0a96bdfd5edae00f691a"},
    {"memory::recall", "3d11f65a1256ce7a81b26b50c5ba38f5e72be08dac35663c78fd5f3ee2aef2ea"},
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
    {"memory::action_create", "87ae5ea7f2e1bb365765c09835d88cb0d8e7ff74c8094b0d8833b5269dffd9d9"},
    {"memory::action_update", "994218489f92b716fa1cea02361f63ad38c7d7e772d08bb20561fe9ec9e164e5"},
    {"memory::frontier", "129a9f4e82812211418fcbd8422f0b3ebadf62a07870f544f07285677604dd7a"},
    {"memory::next", "129a9f4e82812211418fcbd8422f0b3ebadf62a07870f544f07285677604dd7a"},
    {"memory::smart_search", "526b71d1976aeb512377a66ade3bca87a018fb42812f753bfe33315daf9cd390"},
    {"memory::sessions", "0bd73d1b6eac090f546dda3945c06b7065cb8f0efa1476ca4de0b510c3f3532d"},
    {"memory::patterns", "22f624a3c35c4845948c4365c72db64f34252f54bb318e5e55efb405d2f295b5"},
    {"memory::timeline", "ad323a6a3990e23952f62f9018a56aec6618f41bfde1e504113ec82204365920"},
    {"memory::export", "0d1ce286ba0cd50f348681dc087e3d973a073a4b7ee764974760974b794ecb88"},
    {"memory::relations", "0910a6da3840d37c4eaee6cc9d0d5fd6a1d8b9b05cef0141ba157a7e2beeda40"},
    {"memory::compress_file", "bb0abc766d39c2a56989d18303623a05e6241e6e1c5701dc0a55f53daaed22a6"},
    {"memory::audit", "dca7422220d538500eb01c1fa7ffe32bcc16f49cfcd21ef80c443b39ccbf852a"},
    {"memory::governance_delete",
     "0b52982f95a278025d8b3620dcc7072cf8644b5505a9705984ee91d1ce82d4cc"},
    {"memory::diagnose", "cadd96657217a7d93bedd0056277d9afb9af80fdcf4890d57aa9dfdec778e09c"},
    {"memory::heal", "7be6fb307419cb44c78b606d887485a7e23aafce8d08d50e3d264e33b0e5502d"}
  ]

  @extended_tool_contracts [
    {"memory::lesson_strengthen",
     "e931d8898a025c162df362fb829ae42d3cfee4737015efc0f298549ac579c698"},
    {"memory::lesson_promote",
     "512fbae38f14307617996baa57f14a55834d822f8d4ee33a08f55ea37085a5ca"},
    {"memory::lesson_archive",
     "a0e583519b6a79c9f0c8fa0969deda62267c8fb8cd6296ac1b544cbb7f6c7301"},
    {"memory::crystallize", "bb7589a37cf5d372d512c4bb480d1b5428b5b0c9fbe605da52a61ad32075fa95"},
    {"memory::replay_import", "8642574f365c9becf4c789047cabb2e14b3335e4964488dcf59703afecc7cd50"},
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

  @replay_tool_contracts [
    {"memory::replay_sessions",
     "feb504a8dc0dd4f0081426366d656d3ba32a16166e74ed7247e1d0326d5ef642"},
    {"memory::replay_load", "ee3448b07e5761a199629e73060cae74241d00aeb046f3673177b372f8ac4782"}
  ]

  @full_tool_contracts Enum.take(@core_tool_contracts, 2) ++
                         @replay_tool_contracts ++
                         Enum.drop(@core_tool_contracts, 2) ++ @extended_tool_contracts

  @worker_options [
    {Backplane.Memory.Workers.AccessWritebackWorker, memory: 3},
    {Backplane.Memory.Workers.EmbedWorker, memory: 5},
    {Backplane.Memory.Workers.EpisodicWorker, memory: 3},
    {Backplane.Memory.Workers.EvictionWorker, memory: 3},
    {Backplane.Memory.Workers.FallbackSweepWorker, memory: 2},
    {Backplane.Memory.Workers.GraphExtractWorker, memory: 3},
    {Backplane.Memory.Workers.LeaseCleanupWorker, memory: 3},
    {Backplane.Memory.Workers.ProceduralWorker, memory: 2},
    {Backplane.Memory.Workers.ProfileBuildWorker, memory: 3},
    {Backplane.Memory.Workers.SummaryWorker, memory: 3}
  ]

  describe "public namespace contract" do
    test "Backplane.Memory exposes version/0 with its current value" do
      assert Backplane.Memory.__info__(:functions) == [version: 0]
      assert Backplane.Memory.version() == "0.1.0"
    end

    test "Memories exposes the supported function arities" do
      assert Backplane.Memory.Memories.__info__(:functions) == @memories_api
    end

    test "Observations exposes the supported function arities" do
      assert Backplane.Memory.Observations.__info__(:functions) == @observation_api
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

    test "exposes the exact default tool names and schemas" do
      saved_setting = preserve_ets_key(:backplane_settings, "memory.tools")
      on_exit(fn -> restore_ets_key(:backplane_settings, "memory.tools", saved_setting) end)
      :ets.delete(:backplane_settings, "memory.tools")

      assert tool_contract(Service.tools()) == @core_tool_contracts
    end

    test "remember requires caller content and agent while rejecting ownership fields" do
      tools = Service.tools()
      schema = tools |> Enum.find(&(&1.name == "memory::remember")) |> Map.fetch!(:input_schema)

      facet_tag_schema =
        tools |> Enum.find(&(&1.name == "memory::facet_tag")) |> Map.fetch!(:input_schema)

      assert schema["required"] == ["content", "agent_id"]
      assert schema["additionalProperties"] == false
      assert schema["properties"]["facets"] == facet_tag_schema["properties"]["facets"]
      refute Map.has_key?(schema["properties"], "host_id")
      refute Map.has_key?(schema["properties"], "client_id")

      assert {:error, message} =
               InputValidator.validate(
                 %{"content" => "memory", "agent_id" => "agent", "host_id" => "forged"},
                 schema
               )

      assert message =~ "Unexpected arguments: host_id"
    end

    test "exposes the exact full tool names and schemas" do
      saved =
        preserve_settings(
          ~w(memory.tools memory.pipeline.enabled memory.replay_enabled memory.replay_import_enabled)
        )

      on_exit(fn -> restore_settings(saved) end)

      for {key, value} <- [
            {"memory.tools", "all"},
            {"memory.pipeline.enabled", true},
            {"memory.replay_enabled", true},
            {"memory.replay_import_enabled", true}
          ],
          do: put_ets_setting(key, value)

      assert tool_contract(Service.tools()) == @full_tool_contracts
    end

    test "application lifecycle registers tools when enabled and cleans up memory prompts" do
      sandbox_auto!()
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

      :ok = Application.stop(:backplane_memory)
      PromptRegistry.clear()

      assert :ok =
               PromptRegistry.register_managed(
                 "other",
                 [%{name: "daily_agenda", description: "Agenda", arguments: []}],
                 Service
               )

      put_ets_setting("services.memory.enabled", false)
      assert {:ok, _} = Application.ensure_all_started(:backplane_memory)
      assert Enum.map(PromptRegistry.list(), & &1.name) == ["daily_agenda"]

      assert :ok = Application.stop(:backplane_memory)
      put_ets_setting("services.memory.enabled", true)
      assert {:ok, _} = Application.ensure_all_started(:backplane_memory)
      assert Enum.any?(PromptRegistry.list(), &(&1.prefix == "memory"))

      assert :ok = Application.stop(:backplane_memory)
      assert Enum.map(PromptRegistry.list(), & &1.name) == ["daily_agenda"]
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

  defp preserve_settings(keys),
    do: Map.new(keys, &{&1, preserve_ets_key(:backplane_settings, &1)})

  defp restore_settings(saved),
    do: Enum.each(saved, fn {key, rows} -> restore_ets_key(:backplane_settings, key, rows) end)

  defp sandbox_auto! do
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :manual) end)
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {started, _description, _version} ->
      started == application
    end)
  end
end
