# Run only through the supported development shell. This creates configuration
# and registered identities, never derived memories, projections or job outputs.
if Mix.env() != :dev, do: raise("local fixture setup requires MIX_ENV=dev")
Logger.configure(level: :warning)
run_id = System.fetch_env!("MEMORY_LOCAL_RUN_ID")
unless Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,49}$/, run_id), do: raise("invalid run ID")
provider_key = System.fetch_env!("OPENROUTER_API_KEY")
if String.trim(provider_key) == "", do: raise("OPENROUTER_API_KEY is empty")

{:ok, _} = Application.ensure_all_started(:backplane_skills)
{:ok, _} = Backplane.Settings.fetch_many(["memory.pipeline.enabled"])

alias Backplane.{MemorySpaces, Repo, Settings}
alias Backplane.Settings.Credentials
alias Backplane.Skills.{Hosts, Host}
alias Backplane.LLM.{Provider, ProviderApi, ProviderModel, ProviderModelSurface}
alias Backplane.Embedding

root = Path.expand(".devenv/memory-local-fixtures/" <> run_id)
File.mkdir_p!(root)
File.chmod!(root, 0o700)

write_private = fn path, content ->
  # Refuse symlinks before opening credential-bearing files.
  case File.lstat(path) do
    {:error, :enoent} -> :ok
    {:ok, %{type: :regular}} -> :ok
    _ -> raise("unsafe fixture output path")
  end

  File.write!(path, content)
  File.chmod!(path, 0o600)
end

hosts =
  for suffix <- ["primary", "isolated"] do
    name = "memory-local-#{run_id}-#{suffix}"
    scope = "memory_local_#{run_id}_#{suffix}"

    {host, token} =
      case Repo.get_by(Host, name: name) do
        nil ->
          {:ok, host, _auth, token} =
            Hosts.create_agent_with_token(%{name: name, memory_scope: scope})

          {host, token}

        host ->
          [auth | _] = Repo.preload(host, :auth_tokens).auth_tokens
          {:ok, token} = Hosts.reveal_auth_token(auth)
          {host, token}
      end

    {:ok, partition} = MemorySpaces.resolve_host_partition(host.id, scope, "private")
    dir = Path.join(root, suffix)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    yaml = """
    agent:
      host_id: #{host.id}
      machine_name: #{name}
      hub_url: http://localhost:4220
      token: #{token}
      interval_ms: 5000
      work_dir: #{dir}
      manifest_path: #{dir}/manifest.json
      http_bind: 127.0.0.1
      http_port: #{if suffix == "primary", do: 4222, else: 4223}
    memory:
      enabled: true
      db_path: #{dir}/commands.db
      bound_scope: #{scope}
      sync_interval_ms: 1000
      sync_batch_size: 50
      max_attempts: 5
      tombstone_relearn: block
      host_sync:
        enabled: true
        db_path: #{dir}/mirror.db
        development_plaintext: true
        sync_interval_ms: 1000
        max_frame_bytes: 524288
        max_changes: 100
    capture:
      enabled: true
      db_path: #{dir}/capture-spool.db
      upload_interval_ms: 1000
      inject_context: false
    telemetry:
      enabled: false
    targets: []
    """

    config_path = Path.join(dir, "host.yaml")
    write_private.(config_path, yaml)

    %{
      name: name,
      host_id: host.id,
      partition: Map.merge(partition, %{host_id: host.id, client_id: "host:" <> host.id}),
      config: config_path
    }
  end

provider_name = "memory-local-" <> run_id
provider_credential = provider_name <> "-upstream"
resource_credential = provider_name <> "-resource"
{:ok, _} = Credentials.store(provider_credential, provider_key, "llm")

provider =
  case Repo.get_by(Provider, name: provider_name) do
    nil ->
      {:ok, provider} = Provider.create(%{name: provider_name, credential: provider_credential})
      provider

    provider ->
      provider
  end

api =
  case Repo.get_by(ProviderApi, provider_id: provider.id, api_surface: :openai) do
    nil ->
      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "https://openrouter.ai/api/v1",
          native_protocols: [:openai_chat_completions],
          model_discovery_enabled: false
        })

      api

    api ->
      api
  end

models =
  for model_name <- ["openai/gpt-4.1-mini"] do
    model =
      case ProviderModel.get_by_provider_and_model(provider.id, model_name) do
        nil ->
          {:ok, model} =
            ProviderModel.create(%{provider_id: provider.id, model: model_name, source: :manual})

          model

        model ->
          model
      end

    unless ProviderModelSurface.get_by_model_and_api(model.id, api.id) do
      {:ok, _} =
        ProviderModelSurface.create(%{provider_model_id: model.id, provider_api_id: api.id})
    end

    provider_name <> "/" <> model_name
  end

embedding_attrs = %{
  "name" => provider_name,
  "credential" => provider_credential,
  "base_url" => "https://openrouter.ai/api/v1",
  "enabled" => true,
  "model" => "openai/text-embedding-3-large",
  "model_enabled" => true,
  "metadata" => Jason.encode!(%{dimensions: 2560})
}

existing_embedding =
  case Repo.get_by(Embedding.Provider, name: provider_name) do
    nil ->
      nil

    provider ->
      Repo.get_by(Embedding.Model, provider_id: provider.id, model: embedding_attrs["model"])
  end

{:ok, %{provider: embedding_provider, model: embedding_model}} =
  case existing_embedding do
    nil -> Embedding.create_provider_with_model(embedding_attrs)
    model -> Embedding.update_provider_with_model(model, embedding_attrs)
  end

embedding_model_id = Embedding.model_id(%{embedding_model | provider: embedding_provider})
models = models ++ [embedding_model_id]

Code.require_file("memory_local_resource_credential.exs", __DIR__)

case Backplane.Scripts.MemoryLocalResourceCredential.prepare(run_id) do
  {:ok, _} -> :ok
  {:error, reason} -> raise("fixture resource credential preparation refused: #{reason}")
end

settings = %{
  "services.memory.enabled" => true,
  "memory.pipeline.enabled" => true,
  "memory.window_summaries.enabled" => true,
  "memory.session_summary.enabled" => true,
  "memory.fact_extraction.enabled" => true,
  "memory.procedure_extraction.enabled" => true,
  "memory.relation_classifier.enabled" => true,
  "memory.recall.enabled" => true,
  "memory.host_sync.enabled" => true,
  "memory.lesson_auto_extract" => true,
  "memory.crystals_enabled" => true,
  "memory.crystal_session_enabled" => true,
  "memory.llm_model" => Enum.at(models, 0),
  "memory.embed_model" => Enum.at(models, 1),
  "memory.proxy_credential" => resource_credential
}

for {key, value} <- settings, do: :ok = Settings.set(key, value)

manifest = %{
  run_id: run_id,
  prepared_at: DateTime.utc_now(),
  revision: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
  hosts: hosts,
  models: models,
  settings: settings,
  evidence_level: "configuration-only"
}

write_private.(Path.join(root, "fixture.json"), Jason.encode!(manifest, pretty: true) <> "\n")
IO.puts("Prepared configuration only: " <> Path.join(root, "fixture.json"))
