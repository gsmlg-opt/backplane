defmodule Backplane.Repo.Migrations.NormalizeOpenaiCodexProviderModelsTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo
  alias Backplane.Repo.Migrations.BackfillOpenaiCodexDiscoveryStaleMarkers, as: Followup
  alias Backplane.Repo.Migrations.NormalizeOpenaiCodexProviderModels, as: Migration

  @canonical_base_url "https://chatgpt.com/backend-api/codex"
  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260904000002_normalize_openai_codex_provider_models.exs",
                    __DIR__
                  )
  @migration_version 20_260_904_000_002
  @followup_path Path.expand(
                   "../../../../priv/repo/migrations/20260904000003_backfill_openai_codex_discovery_stale_markers.exs",
                   __DIR__
                 )
  @followup_version 20_260_904_000_003
  @stale_models [
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex",
    "gpt-5.3-codex-spark"
  ]

  setup_all do
    previous_base_url = Application.get_env(:backplane, :openai_codex_backend_base_url)
    Application.put_env(:backplane, :openai_codex_backend_base_url, "https://runtime.invalid")
    Code.require_file(@migration_path)
    Code.require_file(@followup_path)

    on_exit(fn ->
      if previous_base_url do
        Application.put_env(:backplane, :openai_codex_backend_base_url, previous_base_url)
      else
        Application.delete_env(:backplane, :openai_codex_backend_base_url)
      end
    end)

    :ok
  end

  test "is self-contained and fixes the canonical Codex backend URL" do
    source = File.read!(@migration_path)

    refute source =~ "Backplane.LLM.OpenAICodex"
    assert source =~ @canonical_base_url

    legacy_provider_id = insert_provider("openai-codex")
    blank_provider_id = insert_provider("openai-codex")
    custom_provider_id = insert_provider("openai-codex")
    other_provider_id = insert_provider("openai")

    legacy_api_id = insert_provider_api(legacy_provider_id, "https://api.openai.com/v1")
    blank_api_id = insert_provider_api(blank_provider_id, "")
    custom_api_id = insert_provider_api(custom_provider_id, "https://codex.internal.example/v1")
    other_api_id = insert_provider_api(other_provider_id, "https://api.openai.com/v1")

    run_migration()

    assert base_url(legacy_api_id) == @canonical_base_url
    assert base_url(blank_api_id) == @canonical_base_url
    assert base_url(custom_api_id) == "https://codex.internal.example/v1"
    assert base_url(other_api_id) == "https://api.openai.com/v1"
  end

  test "marks only stale discovered models without changing enablement" do
    stale_provider_id = insert_provider("openai-codex")
    real_provider_id = insert_provider("openai-codex")

    stale_ids =
      Map.new(@stale_models, fn model ->
        metadata = if model == "gpt-5.4", do: %{"slug" => "different-model"}, else: %{}
        {model, insert_model(stale_provider_id, model, "discovered", metadata)}
      end)

    set_enabled(stale_ids["gpt-5.4"], false)

    real_ids =
      Map.new(@stale_models, fn model ->
        {model, insert_model(real_provider_id, model, "discovered", %{"slug" => model})}
      end)

    manual_id = insert_model(stale_provider_id, "manual-model", "manual", %{})

    run_migration()

    assert Map.new(stale_ids, fn {model, id} -> {model, enabled?(id)} end) ==
             Map.new(@stale_models, &{&1, &1 != "gpt-5.4"})

    assert Enum.all?(stale_ids, fn {_model, id} ->
             model_metadata(id)["backplane_discovery_stale"] == true
           end)

    assert Map.new(real_ids, fn {model, id} -> {model, enabled?(id)} end) ==
             Map.new(@stale_models, &{&1, true})

    assert Enum.all?(real_ids, fn {_model, id} ->
             not Map.has_key?(model_metadata(id), "backplane_discovery_stale")
           end)

    assert enabled?(manual_id)
  end

  test "is idempotent" do
    provider_id = insert_provider("openai-codex")
    api_id = insert_provider_api(provider_id, "https://api.openai.com/v1")
    model_id = insert_model(provider_id, "gpt-5.3-codex-spark", "discovered", %{})

    run_migration()
    first_result = {base_url(api_id), enabled?(model_id), model_metadata(model_id)}

    run_migration()
    second_result = {base_url(api_id), enabled?(model_id), model_metadata(model_id)}

    assert first_result ==
             {@canonical_base_url, true, %{"backplane_discovery_stale" => true}}

    assert second_result == first_result
  end

  test "follow-up marks databases that already ran the earlier migration" do
    provider_id = insert_provider("openai-codex")

    stale_ids =
      for model <- ["gpt-5.5", "gpt-5.3-codex", "gpt-5.3-codex-spark"] do
        insert_model(provider_id, model, "discovered", %{})
      end

    genuine_id =
      insert_model(provider_id, "gpt-5.4", "discovered", %{"slug" => "gpt-5.4"})

    manual_id = insert_model(provider_id, "manual-model", "manual", %{})

    run_followup()
    first_result = Enum.map(stale_ids, &{enabled?(&1), model_metadata(&1)})
    run_followup()

    assert Enum.all?(first_result, fn {enabled, metadata} ->
             enabled == true and metadata["backplane_discovery_stale"] == true
           end)

    assert Enum.map(stale_ids, &{enabled?(&1), model_metadata(&1)}) == first_result
    assert enabled?(genuine_id)
    assert enabled?(manual_id)
  end

  defp run_migration do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @migration_version,
      Migration,
      :forward,
      :up,
      :up,
      log: false
    )
  end

  defp run_followup do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @followup_version,
      Followup,
      :forward,
      :up,
      :up,
      log: false
    )
  end

  defp insert_provider(preset_key) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO llm_providers (name, preset_key, credential, inserted_at, updated_at) VALUES ($1, $2, $3, now(), now()) RETURNING id",
        ["codex-migration-#{System.unique_integer([:positive])}", preset_key, "unused"]
      )

    id
  end

  defp insert_provider_api(provider_id, base_url) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO llm_provider_apis (provider_id, api_surface, base_url, inserted_at, updated_at) VALUES ($1, 'openai', $2, now(), now()) RETURNING id",
        [provider_id, base_url]
      )

    id
  end

  defp insert_model(provider_id, model, source, metadata) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO llm_provider_models (provider_id, model, source, metadata, inserted_at, updated_at) VALUES ($1, $2, $3, $4, now(), now()) RETURNING id",
        [provider_id, model, source, metadata]
      )

    id
  end

  defp base_url(id) do
    %{rows: [[base_url]]} =
      Repo.query!("SELECT base_url FROM llm_provider_apis WHERE id = $1", [id])

    base_url
  end

  defp enabled?(id) do
    %{rows: [[enabled]]} =
      Repo.query!("SELECT enabled FROM llm_provider_models WHERE id = $1", [id])

    enabled
  end

  defp set_enabled(id, enabled) do
    Repo.query!("UPDATE llm_provider_models SET enabled = $2 WHERE id = $1", [id, enabled])
  end

  defp model_metadata(id) do
    %{rows: [[metadata]]} =
      Repo.query!("SELECT metadata FROM llm_provider_models WHERE id = $1", [id])

    metadata
  end
end
