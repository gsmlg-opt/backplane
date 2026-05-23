# Backplane Memory — M1: Store & Writes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap `apps/backplane_memory` with the `bpm_memories` table (pgvector `halfvec(2560)`), explicit write/read API (`remember`, `get`, `forget`, `stats`), content dedup by sha256 hash, provenance recording, privacy filtering, and async embedding via an Oban worker that calls vLLM through the LLM proxy.

**Architecture:** New umbrella app `:backplane_memory` depending on `:backplane` for `Backplane.Repo`. Synchronous writes (insert + sha256 dedup + privacy filter); async embedding via `BackplaneMemory.Workers.EmbedWorker` (Oban, `memory` queue) that POSTs to the LLM proxy at `/api/llm/v1/embeddings` using `Req`. If embedding fails, the memory row stays unembedded (recall degrades to keyword-only; no write failure). Recall, consolidation, MCP server, REST, and admin UI are M2–M6.

**Tech Stack:** Elixir/OTP 28, Ecto 3.12, Postgrex, pgvector ≥ 0.7 (`Pgvector.Ecto.HalfVector`, `halfvec` column), Oban 2.18 (`memory` queue), Req 0.5

---

## Scope note: This plan covers M1 only

The PRD has 6 milestones. Each depends on the previous. Plan covers M1 = FR-1, FR-3, FR-4, FR-5, FR-6, FR-13, FR-17. Plans for M2–M6 will be written separately.

---

## File Structure

### New files

| Path | Responsibility |
|------|----------------|
| `apps/backplane_memory/mix.exs` | App definition; depends on `:backplane`, `:req`, `:oban`, `:jason` |
| `apps/backplane_memory/lib/backplane_memory.ex` | Module entry-point |
| `apps/backplane_memory/lib/backplane_memory/application.ex` | OTP Application (minimal, no GenServers in M1) |
| `apps/backplane_memory/lib/backplane_memory/memories/memory.ex` | Ecto schema `bpm_memories` + changeset |
| `apps/backplane_memory/lib/backplane_memory/privacy/filter.ex` | Strip secrets and `<private>` tags before write |
| `apps/backplane_memory/lib/backplane_memory/memory.ex` | Context API: `remember/2`, `get/1`, `forget/1`, `stats/0` |
| `apps/backplane_memory/lib/backplane_memory/embedding/client.ex` | POST to LLM proxy `/api/llm/v1/embeddings` |
| `apps/backplane_memory/lib/backplane_memory/workers/embed_worker.ex` | Oban worker: embed one `bpm_memories` row |
| `apps/backplane_memory/test/test_helper.exs` | ExUnit + Ecto sandbox setup |
| `apps/backplane_memory/test/support/data_case.ex` | Ecto sandbox test helper |
| `apps/backplane_memory/test/backplane_memory/memories/memory_test.exs` | Schema + changeset tests |
| `apps/backplane_memory/test/backplane_memory/privacy/filter_test.exs` | Privacy filter tests |
| `apps/backplane_memory/test/backplane_memory/memory_test.exs` | Context API tests |
| `apps/backplane_memory/test/backplane_memory/embedding/client_test.exs` | Embedding client tests (mock HTTP) |
| `apps/backplane_memory/test/backplane_memory/workers/embed_worker_test.exs` | Embed worker tests |

### Modified files

| Path | Change |
|------|--------|
| `apps/backplane/priv/repo/migrations/20260523000001_create_bpm_memories.exs` | New table with `halfvec(2560)`, generated `tsvector`, HNSW index |
| `config/config.exs` | Add `memory: 3` to Oban queues |

### NOT modified

| Path | Reason |
|------|--------|
| `apps/backplane/mix.exs` | `backplane_memory` depends on `backplane`, not the other way around — no circular dep |
| `apps/backplane/lib/backplane/application.ex` | `backplane_memory` starts via its own OTP app in the umbrella |

---

## Task 1: App Scaffold

**Files:**
- Create: `apps/backplane_memory/mix.exs`
- Create: `apps/backplane_memory/lib/backplane_memory.ex`
- Create: `apps/backplane_memory/lib/backplane_memory/application.ex`
- Create: `apps/backplane_memory/test/test_helper.exs`
- Create: `apps/backplane_memory/test/support/data_case.ex`
- Modify: `config/config.exs`

- [ ] **Step 1: Create `apps/backplane_memory/mix.exs`**

```elixir
defmodule BackplaneMemory.MixProject do
  use Mix.Project

  def project do
    [
      app: :backplane_memory,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {BackplaneMemory.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:backplane, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5", override: true},
      {:oban, "~> 2.18"}
    ]
  end
end
```

- [ ] **Step 2: Create `apps/backplane_memory/lib/backplane_memory.ex`**

```elixir
defmodule BackplaneMemory do
  @moduledoc "Self-hosted agent memory for Backplane."

  def version, do: "0.1.0"
end
```

- [ ] **Step 3: Create `apps/backplane_memory/lib/backplane_memory/application.ex`**

```elixir
defmodule BackplaneMemory.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: BackplaneMemory.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 4: Create `apps/backplane_memory/test/test_helper.exs`**

```elixir
Ecto.Adapters.SQL.Sandbox.mode(Backplane.Repo, :manual)
ExUnit.start()
```

- [ ] **Step 5: Create `apps/backplane_memory/test/support/data_case.ex`**

```elixir
defmodule BackplaneMemory.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Backplane.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    :ok
  end
end
```

- [ ] **Step 6: Add `memory: 3` to Oban queues in `config/config.exs`**

Find the line:
```elixir
  queues: [default: 10, indexing: 5, sync: 3, embeddings: 2, llm: 5]
```
Replace with:
```elixir
  queues: [default: 10, indexing: 5, sync: 3, embeddings: 2, llm: 5, memory: 3]
```

- [ ] **Step 7: Verify the app compiles from the umbrella root**

Run: `mix compile`
Expected: no errors; `backplane_memory` appears in compilation output

- [ ] **Step 8: Commit**

```bash
git add apps/backplane_memory/ config/config.exs
git commit -m "feat(memory): scaffold backplane_memory umbrella app"
```

---

## Task 2: DB Migration

**Files:**
- Create: `apps/backplane/priv/repo/migrations/20260523000001_create_bpm_memories.exs`

- [ ] **Step 1: Create the migration**

```elixir
defmodule Backplane.Repo.Migrations.CreateBpmMemories do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:bpm_memories, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :content, :text, null: false
      add :memory_type, :text, null: false, default: "semantic"
      add :scope, :text, null: false, default: "global"
      add :agent_id, :text, null: false
      add :host_id, :text, null: false
      add :client_id, :text
      add :session_id, :text
      add :tags, {:array, :text}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :embedding_model, :text, default: "Qwen/Qwen3-Embedding-4B"
      add :content_hash, :binary, null: false
      add :confidence, :float, null: false, default: 1.0
      add :access_count, :integer, null: false, default: 0
      add :accessed_at, :utc_datetime_usec
      add :superseded_by, :binary_id
      add :expires_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # halfvec(2560) — added via raw SQL; pgvector ≥ 0.7 required
    execute "ALTER TABLE bpm_memories ADD COLUMN embedding halfvec(2560)"

    # generated tsvector for FTS (Postgres 12+)
    execute """
    ALTER TABLE bpm_memories
      ADD COLUMN search_tsv tsvector
      GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, ''))) STORED
    """

    create constraint(:bpm_memories, :bpm_memories_memory_type_check,
             check: "memory_type IN ('working', 'episodic', 'semantic', 'procedural')"
           )

    # HNSW index for halfvec cosine similarity
    execute "CREATE INDEX bpm_memories_embedding_hnsw_idx ON bpm_memories USING hnsw (embedding halfvec_cosine_ops)"

    create index(:bpm_memories, [:search_tsv], using: :gin, name: :bpm_memories_search_tsv_gin_idx)
    create index(:bpm_memories, [:tags], using: :gin, name: :bpm_memories_tags_gin_idx)
    create index(:bpm_memories, [:scope, :memory_type])
    create index(:bpm_memories, [:session_id])
    create index(:bpm_memories, [:content_hash])
    create index(:bpm_memories, [:agent_id])
    create index(:bpm_memories, [:client_id])
    create index(:bpm_memories, [:deleted_at])
  end

  def down do
    drop_if_exists table(:bpm_memories)
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: output includes `== Running 20260523000001 CreateBpmMemories ==` with no errors

- [ ] **Step 3: Verify the table structure**

Run: `mix run --no-start -e 'IO.inspect Backplane.Repo.query!("SELECT column_name, data_type FROM information_schema.columns WHERE table_name = '"'"'bpm_memories'"'"' ORDER BY ordinal_position").rows'`
Expected: list includes `embedding` as `USER-DEFINED` and `search_tsv` as `tsvector`

- [ ] **Step 4: Commit**

```bash
git add apps/backplane/priv/repo/migrations/20260523000001_create_bpm_memories.exs
git commit -m "feat(memory): add bpm_memories migration with halfvec(2560) and generated tsvector"
```

---

## Task 3: Ecto Schema

**Files:**
- Create: `apps/backplane_memory/lib/backplane_memory/memories/memory.ex`
- Create: `apps/backplane_memory/test/backplane_memory/memories/memory_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# apps/backplane_memory/test/backplane_memory/memories/memory_test.exs
defmodule BackplaneMemory.Memories.MemoryTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Memories.Memory

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = Memory.changeset(%Memory{}, %{content: "Paris is the capital of France.", agent_id: "a", host_id: "h"})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :memory_type) == "semantic"
      assert Ecto.Changeset.get_change(cs, :scope) == "global"
    end

    test "content is required" do
      cs = Memory.changeset(%Memory{}, %{agent_id: "a", host_id: "h"})
      assert %{content: ["can't be blank"]} = errors_on(cs)
    end

    test "agent_id is required" do
      cs = Memory.changeset(%Memory{}, %{content: "x", host_id: "h"})
      assert %{agent_id: ["can't be blank"]} = errors_on(cs)
    end

    test "host_id is required" do
      cs = Memory.changeset(%Memory{}, %{content: "x", agent_id: "a"})
      assert %{host_id: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid memory_type is rejected" do
      cs = Memory.changeset(%Memory{}, %{content: "x", agent_id: "a", host_id: "h", memory_type: "invalid"})
      assert %{memory_type: ["is invalid"]} = errors_on(cs)
    end

    test "content_hash is derived from content" do
      cs = Memory.changeset(%Memory{}, %{content: "hello", agent_id: "a", host_id: "h"})
      assert Ecto.Changeset.get_change(cs, :content_hash) == :crypto.hash(:sha256, "hello")
    end
  end

  describe "Repo.insert/1" do
    test "inserts a valid memory row" do
      {:ok, mem} =
        %Memory{}
        |> Memory.changeset(%{content: "Rome is the capital of Italy.", agent_id: "a", host_id: "h"})
        |> Backplane.Repo.insert()

      assert mem.id != nil
      assert mem.memory_type == "semantic"
      assert mem.scope == "global"
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane_memory/test/backplane_memory/memories/memory_test.exs`
Expected: compile error `BackplaneMemory.Memories.Memory is undefined`

- [ ] **Step 3: Implement the schema**

```elixir
# apps/backplane_memory/lib/backplane_memory/memories/memory.ex
defmodule BackplaneMemory.Memories.Memory do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_types ~w(working episodic semantic procedural)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "bpm_memories" do
    field :content, :string
    field :memory_type, :string, default: "semantic"
    field :scope, :string, default: "global"
    field :agent_id, :string
    field :host_id, :string
    field :client_id, :string
    field :session_id, :string
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.HalfVector
    field :embedding_model, :string, default: "Qwen/Qwen3-Embedding-4B"
    field :content_hash, :binary
    field :confidence, :float, default: 1.0
    field :access_count, :integer, default: 0
    field :accessed_at, :utc_datetime_usec
    field :superseded_by, :binary_id
    field :expires_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [
      :content, :memory_type, :scope, :agent_id, :host_id,
      :client_id, :session_id, :tags, :metadata,
      :embedding, :embedding_model,
      :confidence, :access_count, :accessed_at,
      :superseded_by, :expires_at, :deleted_at
    ])
    |> validate_required([:content, :agent_id, :host_id])
    |> validate_inclusion(:memory_type, @valid_types)
    |> derive_content_hash()
  end

  def embed_changeset(memory, vector) do
    # vector is a list of floats; Pgvector.Ecto.HalfVector.cast/1 wraps it
    change(memory, embedding: Pgvector.HalfVector.new(vector))
  end

  defp derive_content_hash(changeset) do
    case get_change(changeset, :content) do
      nil -> changeset
      content -> put_change(changeset, :content_hash, :crypto.hash(:sha256, content))
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/backplane_memory/test/backplane_memory/memories/memory_test.exs`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/backplane_memory/lib/backplane_memory/memories/ apps/backplane_memory/test/backplane_memory/memories/
git commit -m "feat(memory): add Memory Ecto schema with changeset and sha256 content_hash"
```

---

## Task 4: Privacy Filter

**Files:**
- Create: `apps/backplane_memory/lib/backplane_memory/privacy/filter.ex`
- Create: `apps/backplane_memory/test/backplane_memory/privacy/filter_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# apps/backplane_memory/test/backplane_memory/privacy/filter_test.exs
defmodule BackplaneMemory.Privacy.FilterTest do
  use ExUnit.Case, async: true

  alias BackplaneMemory.Privacy.Filter

  describe "apply/1" do
    test "passes through normal content unchanged" do
      assert Filter.apply("The meeting is at 3pm.") == {:ok, "The meeting is at 3pm."}
    end

    test "strips <private> tagged content" do
      assert Filter.apply("<private>my secret</private>") == {:ok, "[REDACTED]"}
    end

    test "strips OpenAI/Anthropic-style API keys (sk- prefix)" do
      input = "Use key sk-1234567890abcdefABCDEFabcdef123456"
      {:ok, result} = Filter.apply(input)
      refute result =~ "sk-1234567890"
      assert result =~ "[REDACTED]"
    end

    test "strips AWS access key IDs (AKIA prefix)" do
      input = "AKIA1234567890ABCDEF is the key"
      {:ok, result} = Filter.apply(input)
      refute result =~ "AKIA1234567890ABCDEF"
      assert result =~ "[REDACTED]"
    end

    test "multi-line content: strips only the private block" do
      input = "Facts:\n<private>my password</private>\nMore facts."
      {:ok, result} = Filter.apply(input)
      assert result =~ "Facts:"
      assert result =~ "More facts."
      refute result =~ "my password"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane_memory/test/backplane_memory/privacy/filter_test.exs`
Expected: compile error `BackplaneMemory.Privacy.Filter is undefined`

- [ ] **Step 3: Implement the privacy filter**

```elixir
# apps/backplane_memory/lib/backplane_memory/privacy/filter.ex
defmodule BackplaneMemory.Privacy.Filter do
  @moduledoc "Strips secrets and <private>-tagged content before memory storage."

  @secret_patterns [
    # OpenAI / Anthropic keys: sk- prefix + 20+ alphanumeric chars
    ~r/sk-[A-Za-z0-9]{20,}/,
    # AWS access key IDs
    ~r/AKIA[0-9A-Z]{16}/,
    # Explicit api_key / access_token assignments
    ~r/(?i)(?:api[_-]?key|access[_-]?token|bearer)[[:space:]]*[:=][[:space:]]*["']?([A-Za-z0-9+\/\-_]{20,})["']?/
  ]

  @spec apply(String.t()) :: {:ok, String.t()}
  def apply(content) when is_binary(content) do
    result =
      content
      |> strip_private_tags()
      |> redact_secrets()

    {:ok, result}
  end

  defp strip_private_tags(content) do
    Regex.replace(~r/<private>.*?<\/private>/s, content, "[REDACTED]")
  end

  defp redact_secrets(content) do
    Enum.reduce(@secret_patterns, content, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/backplane_memory/test/backplane_memory/privacy/filter_test.exs`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/backplane_memory/lib/backplane_memory/privacy/ apps/backplane_memory/test/backplane_memory/privacy/
git commit -m "feat(memory): add privacy filter for secrets and <private> content"
```

---

## Task 5: Context API

**Files:**
- Create: `apps/backplane_memory/lib/backplane_memory/memory.ex`
- Create a stub `apps/backplane_memory/lib/backplane_memory/workers/embed_worker.ex` (replaced in Task 7)
- Create: `apps/backplane_memory/test/backplane_memory/memory_test.exs`

- [ ] **Step 1: Create the EmbedWorker stub so Memory context compiles**

```elixir
# apps/backplane_memory/lib/backplane_memory/workers/embed_worker.ex
defmodule BackplaneMemory.Workers.EmbedWorker do
  @doc "Stub: replaced in Task 7 with full Oban worker."
  def enqueue(_id), do: {:ok, nil}
end
```

- [ ] **Step 2: Write the failing test**

```elixir
# apps/backplane_memory/test/backplane_memory/memory_test.exs
defmodule BackplaneMemory.MemoryTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Memory

  describe "remember/2" do
    test "stores a memory with defaults" do
      assert {:ok, mem} = Memory.remember("Paris is the capital of France.", agent_id: "a", host_id: "h")
      assert mem.content == "Paris is the capital of France."
      assert mem.memory_type == "semantic"
      assert mem.scope == "global"
    end

    test "respects explicit type and scope options" do
      assert {:ok, mem} = Memory.remember("turn content", type: "working", scope: "proj-x", agent_id: "a", host_id: "h")
      assert mem.memory_type == "working"
      assert mem.scope == "proj-x"
    end

    test "deduplicates identical content within same scope (returns existing id)" do
      opts = [agent_id: "a", host_id: "h", scope: "proj-1"]
      {:ok, first} = Memory.remember("Unique fact.", opts)
      {:ok, second} = Memory.remember("Unique fact.", opts)
      assert first.id == second.id
    end

    test "does not deduplicate across different scopes" do
      {:ok, first} = Memory.remember("Fact.", agent_id: "a", host_id: "h", scope: "scope-1")
      {:ok, second} = Memory.remember("Fact.", agent_id: "a", host_id: "h", scope: "scope-2")
      assert first.id != second.id
    end

    test "strips secrets via privacy filter before storing" do
      {:ok, mem} = Memory.remember("Key: sk-abcdef1234567890abcdef1234567890abcdef12", agent_id: "a", host_id: "h")
      refute mem.content =~ "sk-abcdef"
      assert mem.content =~ "[REDACTED]"
    end

    test "returns error when agent_id is missing" do
      assert {:error, _changeset} = Memory.remember("x", host_id: "h")
    end
  end

  describe "get/1" do
    test "retrieves a non-deleted memory by id" do
      {:ok, mem} = Memory.remember("Berlin is in Germany.", agent_id: "a", host_id: "h")
      assert {:ok, fetched} = Memory.get(mem.id)
      assert fetched.id == mem.id
    end

    test "returns not_found for unknown id" do
      assert {:error, :not_found} = Memory.get(Ecto.UUID.generate())
    end
  end

  describe "forget/1" do
    test "tombstones a memory — get/1 returns not_found afterwards" do
      {:ok, mem} = Memory.remember("Tokyo is in Japan.", agent_id: "a", host_id: "h")
      assert :ok = Memory.forget(mem.id)
      assert {:error, :not_found} = Memory.get(mem.id)
    end

    test "returns not_found for unknown id" do
      assert {:error, :not_found} = Memory.forget(Ecto.UUID.generate())
    end
  end

  describe "stats/0" do
    test "returns a list with memory_type and count keys" do
      Memory.remember("s1", agent_id: "a", host_id: "h", type: "semantic")
      Memory.remember("s2", agent_id: "a", host_id: "h", type: "working")
      stats = Memory.stats()
      assert is_list(stats)
      assert Enum.any?(stats, fn s -> Map.has_key?(s, :memory_type) and Map.has_key?(s, :count) end)
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test apps/backplane_memory/test/backplane_memory/memory_test.exs`
Expected: compile error `BackplaneMemory.Memory is undefined`

- [ ] **Step 4: Implement the context API**

```elixir
# apps/backplane_memory/lib/backplane_memory/memory.ex
defmodule BackplaneMemory.Memory do
  @moduledoc "Context API: remember, get, forget, stats."

  import Ecto.Query

  alias Backplane.Repo
  alias BackplaneMemory.Memories.Memory, as: MemorySchema
  alias BackplaneMemory.Privacy.Filter
  alias BackplaneMemory.Workers.EmbedWorker

  @dedup_window_seconds 86_400

  @doc """
  Persist a memory. Deduplicates by sha256(content) within the same scope over a 24-hour window.
  Options: type (default "semantic"), scope (default "global"), agent_id, host_id,
           client_id, session_id, tags, metadata.
  """
  @spec remember(String.t(), keyword()) :: {:ok, MemorySchema.t()} | {:error, term()}
  def remember(content, opts \\ []) do
    with {:ok, filtered} <- Filter.apply(content) do
      attrs = build_attrs(filtered, opts)
      hash = :crypto.hash(:sha256, filtered)

      case find_duplicate(hash, attrs.scope) do
        %MemorySchema{} = existing ->
          {:ok, existing}

        nil ->
          %MemorySchema{}
          |> MemorySchema.changeset(attrs)
          |> Repo.insert()
          |> tap_enqueue_embed()
      end
    end
  end

  @doc "Fetch a non-deleted memory by id."
  @spec get(String.t()) :: {:ok, MemorySchema.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get_by(MemorySchema, id: id, deleted_at: nil) do
      nil -> {:error, :not_found}
      mem -> {:ok, mem}
    end
  end

  @doc "Soft-delete a memory by id."
  @spec forget(String.t()) :: :ok | {:error, :not_found}
  def forget(id) do
    case Repo.get_by(MemorySchema, id: id, deleted_at: nil) do
      nil ->
        {:error, :not_found}

      mem ->
        mem
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update!()

        :ok
    end
  end

  @doc "Return counts grouped by memory_type (non-deleted rows only)."
  @spec stats() :: [%{memory_type: String.t(), count: integer()}]
  def stats do
    MemorySchema
    |> where([m], is_nil(m.deleted_at))
    |> group_by([m], m.memory_type)
    |> select([m], %{memory_type: m.memory_type, count: count(m.id)})
    |> Repo.all()
  end

  defp build_attrs(content, opts) do
    %{
      content: content,
      memory_type: Keyword.get(opts, :type, "semantic"),
      scope: Keyword.get(opts, :scope, "global"),
      agent_id: Keyword.get(opts, :agent_id, ""),
      host_id: Keyword.get(opts, :host_id, ""),
      client_id: Keyword.get(opts, :client_id),
      session_id: Keyword.get(opts, :session_id),
      tags: Keyword.get(opts, :tags, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp find_duplicate(content_hash, scope) do
    window_start = DateTime.add(DateTime.utc_now(), -@dedup_window_seconds, :second)

    MemorySchema
    |> where([m], m.content_hash == ^content_hash)
    |> where([m], m.scope == ^scope)
    |> where([m], is_nil(m.deleted_at))
    |> where([m], m.inserted_at >= ^window_start)
    |> limit(1)
    |> Repo.one()
  end

  defp tap_enqueue_embed({:ok, mem} = result) do
    EmbedWorker.enqueue(mem.id)
    result
  end

  defp tap_enqueue_embed(error), do: error
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/backplane_memory/test/backplane_memory/memory_test.exs`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add apps/backplane_memory/lib/backplane_memory/memory.ex apps/backplane_memory/lib/backplane_memory/workers/embed_worker.ex apps/backplane_memory/test/backplane_memory/memory_test.exs
git commit -m "feat(memory): add Memory context API (remember/get/forget/stats)"
```

---

## Task 6: Embedding Client

**Files:**
- Create: `apps/backplane_memory/lib/backplane_memory/embedding/client.ex`
- Create: `apps/backplane_memory/test/backplane_memory/embedding/client_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# apps/backplane_memory/test/backplane_memory/embedding/client_test.exs
defmodule BackplaneMemory.Embedding.ClientTest do
  use ExUnit.Case, async: true

  alias BackplaneMemory.Embedding.Client

  describe "query_instruction/0" do
    test "returns non-empty string starting with 'Instruct:'" do
      assert String.starts_with?(Client.query_instruction(), "Instruct:")
    end
  end

  describe "embed/3" do
    test "returns {:error, _} on non-200 response" do
      mock = fn req ->
        {req, Req.Response.new(status: 500, body: %{"error" => "oops"})}
      end

      assert {:error, msg} = Client.embed(["text"], :document, req_options: [adapter: mock])
      assert msg =~ "500"
    end

    test "returns {:ok, vectors} on success with 2560-dim vector" do
      vector = Enum.map(1..2560, fn _ -> 0.001 end)

      mock = fn req ->
        body = %{"data" => [%{"embedding" => vector, "index" => 0}]}
        {req, Req.Response.new(status: 200, body: body)}
      end

      assert {:ok, [result_vec]} = Client.embed(["hello"], :document, req_options: [adapter: mock])
      assert length(result_vec) == 2560
    end

    test "sorts results by index when multiple texts embedded" do
      v1 = Enum.map(1..2560, fn _ -> 0.1 end)
      v2 = Enum.map(1..2560, fn _ -> 0.2 end)

      mock = fn req ->
        body = %{"data" => [%{"embedding" => v2, "index" => 1}, %{"embedding" => v1, "index" => 0}]}
        {req, Req.Response.new(status: 200, body: body)}
      end

      assert {:ok, [first, second]} = Client.embed(["a", "b"], :document, req_options: [adapter: mock])
      assert hd(first) == 0.1
      assert hd(second) == 0.2
    end

    test "query mode prepends instruction prefix to each input" do
      received_body = :persistent_term.get({__MODULE__, :body}, nil)
      _ = received_body

      pid = self()

      mock = fn req ->
        send(pid, {:input, req.body["input"]})
        body = %{"data" => [%{"embedding" => Enum.map(1..2560, fn _ -> 0.0 end), "index" => 0}]}
        {req, Req.Response.new(status: 200, body: body)}
      end

      Client.embed(["my query"], :query, req_options: [adapter: mock])

      assert_receive {:input, [prefixed]}
      assert String.starts_with?(prefixed, "Instruct:")
    end

    test "returns {:error, _} on network failure" do
      mock = fn req -> {req, %Req.TransportError{reason: :econnrefused}} end
      assert {:error, _} = Client.embed(["text"], :document, req_options: [adapter: mock])
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane_memory/test/backplane_memory/embedding/client_test.exs`
Expected: compile error `BackplaneMemory.Embedding.Client is undefined`

- [ ] **Step 3: Implement the embedding client**

```elixir
# apps/backplane_memory/lib/backplane_memory/embedding/client.ex
defmodule BackplaneMemory.Embedding.Client do
  @moduledoc """
  Embeds text via vLLM (Qwen3-Embedding-4B) through the Backplane LLM proxy.

  :document mode — plain text for storage
  :query mode — prepends retrieval instruction for asymmetric search quality
  """

  @model "Qwen/Qwen3-Embedding-4B"
  @query_instruction "Instruct: Retrieve semantically similar text: Query: "

  @doc "Retrieval instruction prefix used in query mode."
  def query_instruction, do: @query_instruction

  @spec embed([String.t()], :query | :document, keyword()) ::
          {:ok, [[float()]]} | {:error, String.t()}
  def embed(texts, mode, opts \\ []) when mode in [:query, :document] do
    inputs = prepare_inputs(texts, mode)
    base_url = Application.get_env(:backplane_memory, :llm_proxy_url, "http://localhost:4220")
    url = "#{base_url}/api/llm/v1/embeddings"
    req_options = Keyword.get(opts, :req_options, [])

    req_opts =
      [
        url: url,
        json: %{model: @model, input: inputs, encoding_format: "float"},
        headers: [{"content-type", "application/json"}]
      ] ++ req_options

    case Req.post(req_opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        vectors =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, vectors}

      {:ok, %{status: status, body: body}} ->
        {:error, "LLM proxy returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp prepare_inputs(texts, :document), do: texts
  defp prepare_inputs(texts, :query), do: Enum.map(texts, &(@query_instruction <> &1))
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/backplane_memory/test/backplane_memory/embedding/client_test.exs`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/backplane_memory/lib/backplane_memory/embedding/ apps/backplane_memory/test/backplane_memory/embedding/
git commit -m "feat(memory): add embedding client for vLLM via LLM proxy"
```

---

## Task 7: Embed Worker

**Files:**
- Modify: `apps/backplane_memory/lib/backplane_memory/workers/embed_worker.ex` (replace stub from Task 5)
- Create: `apps/backplane_memory/test/backplane_memory/workers/embed_worker_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# apps/backplane_memory/test/backplane_memory/workers/embed_worker_test.exs
defmodule BackplaneMemory.Workers.EmbedWorkerTest do
  use BackplaneMemory.DataCase, async: false

  alias BackplaneMemory.Memory
  alias BackplaneMemory.Workers.EmbedWorker
  alias BackplaneMemory.Memories.Memory, as: MemorySchema

  describe "perform_with_client/2" do
    test "updates the embedding field of a memory row" do
      {:ok, mem} = Memory.remember("London is in the UK.", agent_id: "a", host_id: "h")
      assert is_nil(Backplane.Repo.get!(MemorySchema, mem.id).embedding)

      vector = Enum.map(1..2560, fn _ -> 0.001 end)
      mock_embed = fn _texts, _mode, _opts -> {:ok, [vector]} end

      assert :ok = EmbedWorker.perform_with_client(%Oban.Job{args: %{"id" => mem.id}}, mock_embed)

      updated = Backplane.Repo.get!(MemorySchema, mem.id)
      assert updated.embedding != nil
    end

    test "returns :ok and leaves embedding nil when embed client fails" do
      {:ok, mem} = Memory.remember("Madrid is in Spain.", agent_id: "a", host_id: "h")
      failing_embed = fn _texts, _mode, _opts -> {:error, "vLLM unavailable"} end

      assert :ok = EmbedWorker.perform_with_client(%Oban.Job{args: %{"id" => mem.id}}, failing_embed)

      updated = Backplane.Repo.get!(MemorySchema, mem.id)
      assert is_nil(updated.embedding)
    end

    test "returns :ok for a non-existent memory id (graceful skip)" do
      job = %Oban.Job{args: %{"id" => Ecto.UUID.generate()}}
      mock_embed = fn _texts, _mode, _opts -> {:ok, [[]]} end
      assert :ok = EmbedWorker.perform_with_client(job, mock_embed)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/backplane_memory/test/backplane_memory/workers/embed_worker_test.exs`
Expected: errors because `EmbedWorker` is a stub without `perform_with_client/2`

- [ ] **Step 3: Replace the stub with the full Oban worker**

```elixir
# apps/backplane_memory/lib/backplane_memory/workers/embed_worker.ex
defmodule BackplaneMemory.Workers.EmbedWorker do
  @moduledoc "Oban worker: embed a bpm_memories row via the LLM proxy. Fails gracefully — memory stays unembedded on error."

  use Oban.Worker, queue: :memory, max_attempts: 5

  alias Backplane.Repo
  alias BackplaneMemory.Embedding.Client
  alias BackplaneMemory.Memories.Memory

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    perform_with_client(job, &Client.embed/3)
  end

  @doc "Testable entry-point: accepts an embed_fn instead of the real client."
  def perform_with_client(%Oban.Job{args: %{"id" => id}}, embed_fn) do
    case Repo.get(Memory, id) do
      nil ->
        :ok

      %Memory{} = mem ->
        case embed_fn.([mem.content], :document, []) do
          {:ok, [vector]} ->
            mem |> Memory.embed_changeset(vector) |> Repo.update!()
            :ok

          {:error, _reason} ->
            # Non-fatal: leave embedding nil, recall degrades to keyword-only
            :ok
        end
    end
  end

  @doc "Enqueue an embed job for the given memory id."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(id) do
    %{id: id}
    |> new()
    |> Oban.insert()
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/backplane_memory/test/backplane_memory/workers/embed_worker_test.exs`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add apps/backplane_memory/lib/backplane_memory/workers/ apps/backplane_memory/test/backplane_memory/workers/
git commit -m "feat(memory): add EmbedWorker Oban job for async vLLM embedding"
```

---

## Task 8: Full Suite Verification

- [ ] **Step 1: Run all backplane_memory tests from umbrella root**

Run: `mix test apps/backplane_memory/`
Expected: all tests pass, no compilation warnings

- [ ] **Step 2: Run full umbrella test suite**

Run: `mix test`
Expected: all existing tests still pass (zero regressions)

- [ ] **Step 3: Commit if all green**

```bash
git commit -m "test(memory): M1 full suite green"
```

---

## Self-Review

### Spec Coverage (M1 = FR-1, FR-3, FR-4, FR-5, FR-6, FR-13, FR-17)

| FR | Requirement | Covered? |
|----|-------------|---------|
| FR-1 | Explicit write (`remember`) | ✅ `BackplaneMemory.Memory.remember/2` |
| FR-3 | Dedup by content hash | ✅ `find_duplicate/2` — sha256 + scope + 24h window |
| FR-4 | Provenance (`agent_id` + `host_id`) | ✅ Required fields in schema changeset |
| FR-5 | Scope field (opaque, default `global`) | ✅ `scope` field with default |
| FR-6 | Async embedding via vLLM | ✅ `EmbedWorker` + `Embedding.Client` |
| FR-13 | Forget (tombstone) | ✅ `forget/1` sets `deleted_at` |
| FR-17 | `get` + `stats` | ✅ `get/1`, `stats/0` |
| FR-2 | Auto-capture from `/api/llm/*` | ⏳ M4 |
| FR-7–9 | Recall (hybrid RRF, token budget) | ⏳ M2 |
| FR-10–12 | Consolidation / decay / eviction | ⏳ M3 |
| FR-14 | MCP server + REST `/api/memory/*` | ⏳ M4 |
| FR-15–16 | Host-agent broker + plugins | ⏳ M5 |
| FR-18 | Admin UI | ⏳ M6 |

### Type Consistency

- `Memory.remember/2` → `MemorySchema.changeset/2` (same alias `MemorySchema`) ✅
- `EmbedWorker.enqueue/1` → called in `Memory.tap_enqueue_embed/1` ✅
- `EmbedWorker.perform_with_client/2` → uses `Memory.embed_changeset/2` (same `Memory` alias) ✅
- `Memory.embed_changeset/2` → calls `Pgvector.HalfVector.new(vector)` ✅

### Placeholder Check

None found.

### NFR Check

- NFR-2 (capture is non-blocking): embedding is async (Oban worker) ✅
- NFR-5 (resilience): `EmbedWorker` returns `:ok` on embed failure ✅
- NFR-6 (storage): `halfvec(2560)` column with HNSW index ✅
- NFR-7 (isolation): self-contained app `:backplane_memory` ✅
