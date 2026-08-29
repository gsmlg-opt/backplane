# Memory V2 PR1 Remote-First Facade and Partition Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make host-agent core memory reads canonical while online, preserve durable provisional read-your-writes during outages, complete the current host-private compatibility partition before ACK, and make host-originated forget tombstone canonical memory.

**Architecture:** Add one deep, stateless `Backplane.HostAgent.MemoryFacade.call/3` seam used only by `Services.Memory` for `remember`, `recall`, `list`, `forget`, and `stats`. The facade hides remote-first routing, an allowlisted transport-error classifier, consistency metadata, and provisional overlays without adding a process. Until PR2 supplies a protected, revisioned, quota-bounded edge mirror, outage reads expose only pending local commands and explicitly report historical memory unavailable. The authenticated Channel supplies a complete host-private compatibility partition to capture ingest; `host_memory.v1` remains the transport, `memory::*` remains the public namespace, and the ADR's durable `memory_space_id` mapping stays out of PR1.

**Tech Stack:** Elixir 1.18, OTP 28, Phoenix Channels, Ecto/PostgreSQL, Turso/ex_turso, ExUnit

---

## Fixed PR1 decisions

- External facade interface: `MemoryFacade.call(method, args, context)` only.
- Core facade methods: `remember`, `recall`, `list`, `forget`, and `stats`.
- `remember`/`forget`: local transactional row plus command outbox, marked provisional.
- `recall`/`list`/`stats`: canonical remote first; enumerated transport failures expose provisional commands only, never the legacy facts/local-history query.
- Pending overlay identity: local ID and canonical `remote_id` only. Content hashes never establish canonical identity.
- Public namespace remains `memory::*`. Slot/facet/replay behavior is unchanged.
- Compatibility owner remains the explicitly temporary `client_id = "host:<host_id>"`; PR1 does not claim to complete the accepted `memory_space_id` ADR or its Stage 1 mapping.
- `partition_revision` and edge revision metadata are returned as `nil` until `host_memory.v2` exists.
- Transitional offline reads are `provisional_only`, query-bounded, and visibly incomplete. The legacy `facts`/synced-memory history is never relabelled as an edge mirror or `bounded_stale` result.

## Interface comparison

Three interface shapes were evaluated before planning:

- **Selected:** one `MemoryFacade.call/3` interface. It matches the existing `Services.Memory.call/3` seam and hides routing, fallback, overlay, normalization, and consistency metadata.
- **Rejected:** `execute/3` plus public `merge_tools/2`. Tool-catalog merging belongs in `MemoryRouter`; exposing it would make the facade interface cover two unrelated responsibilities.
- **Rejected:** a public policy DSL with `policy/1`, policy structs, and a runtime struct. Explicit private operation/error tables are useful, but exposing policy makes callers learn implementation choices and adds an interpreter without another production adapter.

The selected module has one external seam, plain injected modules for tests, and no runtime process.

### Task 1: Establish the Facade Interface and Strict Fallback Policy

**Files:**
- Create: `apps/backplane_host_agent/lib/backplane/host_agent/memory_facade.ex`
- Create: `apps/backplane_host_agent/test/backplane/host_agent/memory_facade_test.exs`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_proxy.ex`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory_proxy_test.exs`

- [x] **Step 1: Write RED tests for canonical remote recall**

  Add plain fake adapters and assert the wished-for interface:

  ```elixir
  defmodule RemoteOK do
    def call("recall", _args, _opts) do
      {:ok,
       %{
         "status" => "ok",
         "recall_run_id" => "run-1",
         "results" => [%{"id" => "canonical-1", "content" => "canonical"}]
       }}
    end
  end

  defmodule EmptyOverlay do
    def pending_overlay(_args, _opts),
      do: {:ok, %{"upserts" => [], "delete_ids" => [], "pending_operations" => 0}}

    def recall(_args, _opts), do: send(self(), :unexpected_local_recall)
  end

  test "healthy recall returns canonical Recall V2 metadata without local fallback" do
    assert {:ok,
            %{
              "mode" => "online",
              "authority" => "canonical",
              "consistency" => "canonical",
              "stale" => false,
              "partition_revision" => nil,
              "pending_operations" => 0,
              "recall_run_id" => "run-1",
              "hits" => [%{"id" => "canonical-1"}]
            }} =
             MemoryFacade.call(
               "recall",
               %{"query" => "canonical"},
               %{agent_id: "codex", remote_adapter: RemoteOK, local_adapter: EmptyOverlay}
             )

    refute_received :unexpected_local_recall
  end
  ```

- [x] **Step 2: Run the facade test and verify RED**

  Run:

  ```bash
  devenv shell -- mix test apps/backplane_host_agent/test/backplane/host_agent/memory_facade_test.exs
  ```

  Expected: compilation failure because `Backplane.HostAgent.MemoryFacade` does not exist.

- [x] **Step 3: Write RED tests for the strict fallback allowlist**

  Define deterministic fake adapters:

  ```elixir
  defmodule RemoteNotConnected do
    def call(_method, _args, _opts), do: {:error, :not_connected}
  end

  defmodule RemoteTimeout do
    def call(_method, _args, _opts), do: {:error, :timeout}
  end

  defmodule RemoteUnauthorized do
    def call(_method, _args, _opts), do: {:error, "unauthorized"}
  end

  defmodule RemoteInvalid do
    def call(_method, _args, _opts), do: {:error, "invalid_arguments"}
  end

  defmodule PendingOnly do
    def pending_overlay(_args, _opts) do
      send(self(), :pending_overlay)

      {:ok,
       %{
         "upserts" => [
           %{"id" => "local-1", "content" => "pending local command", "provisional" => true}
         ],
         "delete_ids" => [],
         "pending_operations" => 1
       }}
    end
  end
  ```

  Write separate tests for `RemoteNotConnected`, `RemoteTimeout`, `RemoteUnauthorized`, and `RemoteInvalid`. Add named fakes for `:econnrefused`, `{:socket_closed, :normal}`, `"partition_mismatch"`, and `"memory not found"`. Transport cases must return `mode=offline`, `authority=provisional`, `consistency=provisional_only`, `history_available=false`, and only the pending upsert. Canonical-error cases must prove `:pending_overlay` was not received.

- [x] **Step 4: Implement the minimal deep facade**

  Create one public interface and private routing policy:

  ```elixir
  defmodule Backplane.HostAgent.MemoryFacade do
    @moduledoc "Routes core host memory operations across canonical and provisional stores."

    alias Backplane.HostAgent.{Memory, MemoryProxy}

    @commands ~w(remember forget)
    @reads ~w(recall list stats)

    @spec call(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
    def call(method, args, context)
        when method in @commands and is_map(args) and is_map(context) do
      local_call(method, args, context)
    end

    def call(method, args, context)
        when method in @reads and is_map(args) and is_map(context) do
      remote_first(method, args, context)
    end

    def call(method, _args, _context), do: {:error, {:unknown_method, method}}
  end
  ```

  Production adapters default to `MemoryProxy` and `Memory`. Adapter overrides live only in the context passed by tests. Do not create a GenServer, ETS table, behaviour, public policy function, or result struct.

- [x] **Step 5: Add explicit consistency decoration**

  Use exactly these JSON keys:

  ```elixir
  %{
    "mode" => "online" | "offline",
    "authority" => "canonical" | "canonical_with_provisional" | "provisional",
    "consistency" => "canonical" | "read_your_writes" | "provisional_only",
    "stale" => boolean,
    "as_of" => String.t() | nil,
    "partition_revision" => nil,
    "last_sync_age_seconds" => non_neg_integer | nil,
    "pending_operations" => non_neg_integer,
    "history_available" => boolean
  }
  ```

  Preserve all canonical Recall V2 fields and add `"hits"` as an alias of normalized `"results"`. For list, add `"items"` as the compatibility alias. Do not discard `recall_run_id`, channel status, token counts, or provenance. Online results set `history_available=true`; outage results set `as_of`, `partition_revision`, and `last_sync_age_seconds` to `nil` and `history_available=false`.

- [x] **Step 6: Let facade reads omit path-agent filtering remotely**

  Add an opt-in `inject_agent_id: false` option to `MemoryProxy.call/3` and prove the payload omits `agent_id` for facade reads while existing direct callers retain the current default:

  ```elixir
  arguments =
    if Keyword.get(opts, :inject_agent_id, true),
      do: Map.put(args, "agent_id", agent_id),
      else: args
  ```

  `MemoryFacade` passes `inject_agent_id: false` for `recall`, `list`, and `stats`. Local `remember` continues receiving the path agent through local options.

- [x] **Step 7: Run focused facade/proxy tests and verify GREEN**

  Run:

  ```bash
  devenv shell -- mix test \
    apps/backplane_host_agent/test/backplane/host_agent/memory_facade_test.exs \
    apps/backplane_host_agent/test/backplane/host_agent/memory_proxy_test.exs
  ```

  Expected: zero failures.

- [x] **Step 8: Commit the facade seam**

  ```bash
  git add \
    apps/backplane_host_agent/lib/backplane/host_agent/memory_facade.ex \
    apps/backplane_host_agent/lib/backplane/host_agent/memory_proxy.ex \
    apps/backplane_host_agent/test/backplane/host_agent/memory_facade_test.exs \
    apps/backplane_host_agent/test/backplane/host_agent/memory_proxy_test.exs
  git commit -m "feat(memory): add remote-first host facade"
  ```

### Task 2: Add Provisional Read-Your-Writes Overlay

**Files:**
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_facade.ex`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory_test.exs`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory_facade_test.exs`

- [x] **Step 1: Write RED store tests for pending overlay state**

  Use the real test Turso store to assert:

  ```elixir
  store = start_memory!(tmp_dir)
  opts = memory_opts(store)

  assert {:ok, %{"id" => provisional_id}} =
           Memory.remember(%{"content" => "pending insight"}, opts)

  assert {:ok,
          %{
            "upserts" => [%{"id" => ^provisional_id, "provisional" => true}],
            "delete_ids" => [],
            "pending_operations" => 1
          }} = Memory.pending_overlay(%{"query" => "pending"}, opts)
  ```

  Add separate tests proving a latest pending `forget` appears in `delete_ids`, `remote_id` is preferred when present, `done` outbox rows disappear, `failed` rows are not presented as pending, and scope/query filtering is enforced.

- [x] **Step 2: Run the real-store tests and verify RED**

  Run:

  ```bash
  devenv shell -- mix test apps/backplane_host_agent/test/backplane/host_agent/memory_test.exs
  ```

  Expected: undefined `Memory.pending_overlay/2` or assertion failure.

- [x] **Step 3: Implement one latest-operation query per memory**

  Add `Memory.pending_overlay/2`. Select only latest outbox rows in `pending` or `inflight` state, join their memory row, and return:

  ```elixir
  %{
    "upserts" => [compatibility_item],
    "delete_ids" => [local_or_remote_id],
    "pending_operations" => count
  }
  ```

  Never merge `synced` memories, `done` rows, `failed` rows, or `facts` into the provisional overlay. Do not use content hash as canonical identity.

- [x] **Step 4: Write RED facade merge tests**

  Prove:

  - unmatched pending remember is returned once before canonical ACK;
  - pending forget suppresses the matching canonical result;
  - after ACK maps `remote_id`, canonical result wins and the provisional duplicate disappears;
  - requested recall limit is reapplied after overlay;
  - overlay read failure fails the canonical read rather than falsely claiming canonical consistency.

- [x] **Step 5: Implement minimal overlay merge**

  Merge by canonical `remote_id` when present and local ID otherwise. Pending upserts are marked:

  ```elixir
  %{
    "id" => local_id,
    "canonical_id" => remote_id,
    "origin" => "host_command",
    "authority" => "provisional",
    "provisional" => true
  }
  ```

  A non-empty overlay changes online consistency to `read_your_writes` and authority to `canonical_with_provisional`. During a transport outage, return only the same pending overlay with `consistency=provisional_only`, `authority=provisional`, and `history_available=false`; do not invoke or expose legacy synced memories or facts.

  For online `list`, preserve Backplane's canonical `limit`/`offset` page in `results`/`items` (minus pending-forget suppressions) and expose filtered pending remembers separately as unpaginated `provisional_results`. Exact merged offset pagination cannot be reconstructed from one remote page without a second canonical read. Offline `list` paginates the provisional-only set locally. Query and response overlays are hard-capped at 100 newest unresolved operations and expose `overlay_truncated`; `stats` uses an aggregate-only overlay query and never selects pending content.

- [x] **Step 6: Run host-agent Memory tests and verify GREEN**

  Run:

  ```bash
  devenv shell -- mix test \
    apps/backplane_host_agent/test/backplane/host_agent/memory_test.exs \
    apps/backplane_host_agent/test/backplane/host_agent/memory_facade_test.exs \
    apps/backplane_host_agent/test/backplane/host_agent/memory/syncer_test.exs
  ```

  Expected: zero failures.

- [x] **Step 7: Commit provisional overlay support**

  ```bash
  git add \
    apps/backplane_host_agent/lib/backplane/host_agent/memory.ex \
    apps/backplane_host_agent/lib/backplane/host_agent/memory_facade.ex \
    apps/backplane_host_agent/test/backplane/host_agent/memory_test.exs \
    apps/backplane_host_agent/test/backplane/host_agent/memory_facade_test.exs
  git commit -m "feat(memory): overlay provisional host commands"
  ```

### Task 3: Route Core Tools Through the Facade and Expose Hub Memory Tools

**Files:**
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/services/memory.ex`
- Modify: `apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex`
- Modify: `apps/backplane_host_agent/test/backplane/host_agent/memory_router_test.exs`

- [x] **Step 1: Write RED router tests for remote-first recall**

  Configure a fake facade through the service call context and assert both direct HTTP and MCP `memory::recall` delegate to it rather than calling local `Memory.recall/2`. Assert canonical metadata and `hits` survive JSON encoding.

- [x] **Step 2: Write RED tool-discovery and unknown-memory dispatch tests**

  Assert:

  ```elixir
  assert "memory::recall_explain" in tool_names
  assert Enum.count(tool_names, &(&1 == "memory::recall")) == 1
  ```

  Calling Hub-only `memory::semantic_search` must reach `HubProxy.call_tool/2`. Exact local tool names remain single entries; this task does not rename slots/facets or let Hub duplicates replace them.

- [x] **Step 3: Run router tests and verify RED**

  Run:

  ```bash
  devenv shell -- mix test \
    apps/backplane_host_agent/test/backplane/host_agent/memory_router_test.exs
  ```

  Expected: recall still uses local memory, Hub memory tools are filtered by prefix, and unknown memory calls return local unknown-method errors.

- [x] **Step 4: Delegate only core methods to the facade**

  In `Services.Memory.call/3`:

  ```elixir
  @facade_methods ~w(remember recall list forget stats)

  def call(method, args, ctx) when method in @facade_methods,
    do: MemoryFacade.call(method, args, Map.put_new(ctx, :agent_id, "local"))
  ```

  Keep slot/facet methods and replay import on their current handlers.

- [x] **Step 5: Merge Hub discovery by exact name, not prefix**

  Retain local tools and append only Hub tools whose exact names are absent locally. Do not reject all `memory::*` tools. When a resolved local service returns `{:unknown_method, _}` for an MCP call, forward the original full tool name to HubProxy.

- [x] **Step 6: Run router and host-agent tests and verify GREEN**

  Run:

  ```bash
  devenv shell -- mix test apps/backplane_host_agent/test
  ```

  Expected: zero failures.

- [x] **Step 7: Commit router integration**

  ```bash
  git add \
    apps/backplane_host_agent/lib/backplane/host_agent/services/memory.ex \
    apps/backplane_host_agent/lib/backplane/host_agent/memory_router.ex \
    apps/backplane_host_agent/test/backplane/host_agent/memory_router_test.exs
  git commit -m "fix(memory): route host reads through canonical facade"
  ```

### Task 4: Complete the Host-Private Compatibility Partition Before ACK

**Files:**
- Modify: `apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex`
- Modify: `apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/ingest.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/ingest/upcaster/v1.ex`
- Modify: `apps/backplane_memory/lib/backplane/memory/qualification/runner.ex` (approved scope expansion after fail-closed caller audit)
- Modify: `apps/backplane_memory/test/backplane/memory/ingest_test.exs`
- Modify: `apps/backplane_memory/test/backplane/memory/ingest/upcaster_v1_test.exs`

- [x] **Step 1: Write RED Channel tests for trusted partition context**

  Extend the existing `host_event_ingest` assertion:

  ```elixir
  assert_received {:host_event_ingest,
                   %{
                     host_id: host_id,
                     auth_token_id: token_id,
                     partition: %{
                       host_id: host_id,
                       partition_id: partition_id,
                       scope: scope,
                       namespace: "private"
                     }
                   }, ^payload}

  assert partition_id == "host:#{host.id}"
  assert scope == host.memory_scope
  ```

- [x] **Step 2: Write RED ingest tests for derive-or-reject semantics**

  Add tests proving:

  - omitted source scope persists the authenticated canonical scope;
  - project-derived or otherwise different v1 source scope is retained as `raw_envelope["source_scope"]` but never selects authority;
  - explicit v1 authority keys such as `memory_space_id`, `partition_id`, or `namespace` return per-event permanent `partition_mismatch` before persistence;
  - source `client_id` is retained as `raw_envelope["source_client_id"]` while canonical `client_id` remains `host:<host_id>`;
  - malformed/missing trusted partition cannot produce an accepted event;
  - mixed batches keep accepted/rejected order.

  Add an integration fixture using an actual Codex/Claude-style hook envelope whose source scope is `project:<cwd>` and a host registered with the default `proj_local`; it must be accepted under canonical `proj_local` while retaining the project-derived source scope as provenance.

- [x] **Step 3: Run Channel/ingest/upcaster/schema tests and verify RED**

  Run:

  ```bash
  devenv shell -- mix test \
    apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs \
    apps/backplane_memory/test/backplane/memory/ingest_test.exs \
    apps/backplane_memory/test/backplane/memory/ingest/upcaster_v1_test.exs
  ```

  Expected: current auth context lacks `partition`, source scope is persisted as canonical authority, and prepared capture attributes are not checked for completeness before Store append.

- [x] **Step 4: Add the trusted compatibility partition at the Channel**

  Use the authenticated `socket.assigns.host.id` to reload the current durable host registration immediately before ingest, then build the partition only from that current host record:

  ```elixir
  partition = %{
    host_id: host.id,
    partition_id: "host:#{host.id}",
    scope: host.memory_scope,
    namespace: "private"
  }
  ```

  Include it in the ingest auth context. Do not derive authority from the stale socket copy or from event project, scope, integration, agent, or source client. If the durable host cannot be reloaded, fail closed with `ingest_unavailable` and do not call ingest or ACK.

- [x] **Step 5: Validate the trusted partition and source claims in ingest**

  Resolve the compatibility partition once per batch from the trusted auth context. Source `scope` and `client_id` are provenance in v1, not target claims. Reject only conflicting authority-bearing fields that v1 does not permit (`memory_space_id`, `partition_id`, or `namespace`) and the existing spoofed `host_id`. Rejected authority claims receive:

  ```elixir
  %{
    "event_id" => event_id,
    "status" => "rejected",
    "retryable" => false,
    "reason" => "partition_mismatch"
  }
  ```

  Missing or different source scope never changes the canonical scope. A supplied v1 source scope is privacy-filtered and retained as provenance. It is not consistency-checked against the host registration because existing hooks derive project scopes independently; it never grants access.

- [x] **Step 6: Upcast from the trusted partition and preserve provenance**

  `Upcaster.V1.upcast/2` reads the trusted partition and sets canonical fields from it. Preserve provenance in `raw_envelope`:

  ```elixir
  raw_envelope =
    event
    |> maybe_put("source_client_id", event["client_id"])
    |> maybe_put("source_scope", event["scope"])
    |> Map.put("client_id", partition.partition_id)
    |> Map.put("scope", partition.scope)
    |> Map.put("namespace", partition.namespace)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  ```

  Omit `source_client_id`/`source_scope` when the source value is absent; never invent historical provenance.

- [x] **Step 7: Validate prepared capture attributes before Store append**

  In `Ingest`, after upcasting and before returning `{:persist, ...}`, require non-empty canonical `host_id`, `client_id`, `scope`, `namespace`, `integration`, and `ingest_auth_token_id`, plus a non-empty `raw_envelope`. Return a permanent per-event `invalid_partition` rejection when these are incomplete. Do not change the general `Event.changeset/2`: replay, evaluation, qualification, and legacy writers may carry `schema_version` without capture authentication fields.

- [x] **Step 8: Run scoped ingest tests and verify GREEN**

  Run:

  ```bash
  devenv shell -- mix test \
    apps/backplane_memory/test/backplane/memory/ingest \
    apps/backplane_memory/test/backplane/memory/ingest_test.exs \
    apps/backplane_memory/test/backplane/memory/events/store_test.exs \
    apps/backplane_memory/test/backplane/memory/qualification_test.exs \
    apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs
  ```

  Expected: zero failures.

- [x] **Step 9: Commit partition safety**

  ```bash
  git add \
    apps/backplane_api/lib/backplane/api/channels/host_agent_channel.ex \
    apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs \
    apps/backplane_memory/lib/backplane/memory/ingest.ex \
    apps/backplane_memory/lib/backplane/memory/ingest/upcaster/v1.ex \
    apps/backplane_memory/lib/backplane/memory/qualification/runner.ex \
    apps/backplane_memory/test/backplane/memory/ingest_test.exs \
    apps/backplane_memory/test/backplane/memory/ingest/upcaster_v1_test.exs
  git commit -m "fix(memory): derive capture partition before ack"
  ```

### Task 5: Make Host Forget Apply the Canonical Lifecycle Transition

**Files:**
- Modify: `apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex`
- Modify: `apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs`
- Modify: `apps/backplane_memory/lib/backplane/memory/memories.ex`
- Modify: `apps/backplane_memory/test/backplane/memory/memories/memory_test.exs`

- [x] **Step 1: Change the existing characterization test to RED**

  Replace “acknowledges ... without tombstoning” with the desired contract:

  ```elixir
  test "forget tombstones the canonical mapped memory and remains idempotent" do
    scope = "scope:same-batch"
    host = create_host!("same-batch", scope)

    assert {:ok, %{canonical_id: canonical_id}} =
             HostAgentMemorySync.apply_sync_item(
               host,
               remember_item("local_2", scope, "remember then forget")
             )

    forget = %{"id" => "local_2", "op" => "forget", "scope" => scope}

    assert {:ok, %{status: :ok, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, forget)

    assert %MemorySchema{deleted_at: %DateTime{}, lifecycle_state: "tombstoned"} =
             Repo.get!(MemorySchema, canonical_id)
    assert [%{"remote_id" => ^canonical_id}] =
             HostAgentMemorySync.active_wipes(host, scope)

    assert {:ok, %{status: :duplicate, canonical_id: ^canonical_id}} =
             HostAgentMemorySync.apply_sync_item(host, forget)

    assert 1 == Repo.aggregate(HostMemoryRevocation, :count)
  end
  ```

  Also assert wrong scope/foreign remote IDs leave canonical rows active, a forced canonical lifecycle failure writes no revocation, and host forget remains a soft tombstone even when global hard-delete mode is enabled.

- [x] **Step 2: Run the sync adapter test and verify RED**

  Run:

  ```bash
  devenv shell -- mix test apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs
  ```

  Expected: canonical memory remains active and no wipe is returned.

- [x] **Step 3: Add an explicit always-soft canonical lifecycle operation**

  Add `Memories.tombstone/2` as the narrow canonical operation for host command reconciliation. It must use the same exact-partition row lock, lifecycle changeset, and audit metadata as ordinary soft forget, but it must never consult or perform global hard-delete mode:

  ```elixir
  @spec tombstone(String.t(), map() | keyword()) :: :ok | {:error, :not_found | :unauthorized}
  def tombstone(id, partition) do
    with {:ok, partition} <- exact_partition(partition) do
      tombstone_partitioned(id, partition)
    end
  end
  ```

  Keep ordinary `Memories.forget/2` governance behavior unchanged for direct canonical callers. Add focused tests under both hard-delete settings.

- [x] **Step 4: Implement one atomic host-sync transaction**

  Under the existing host/local advisory lock:

  1. reload and validate host scope;
  2. resolve the host-bound mapping and optional remote ID;
  3. acquire a canonical-memory advisory lock and re-resolve the mapping so different local aliases serialize;
  4. if the mapping is already revoked and canonical memory is tombstoned, return `:duplicate`;
  5. otherwise call `Memories.tombstone/2` with the exact compatibility partition;
  6. insert immutable `HostMemoryRevocation` rows for every accepted same-host alias of that canonical memory in the same outer Repo transaction, verifying any unique conflict matches the expected immutable identity exactly;
  7. return `:ok` only after the lifecycle transition and all revocation writes commit.

  Exact partition:

  ```elixir
  %{
    host_id: host.id,
    client_id: "host:#{host.id}",
    scope: host.memory_scope,
    namespace: "private"
  }
  ```

- [x] **Step 5: Run sync/API tests and verify GREEN**

  Run:

  ```bash
  devenv shell -- mix test \
    apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs \
    apps/backplane_api/test/backplane/api/host_agent_sync_e2e_test.exs \
    apps/backplane_api/test/backplane/api/channels/host_agent_channel_test.exs \
    apps/backplane_memory/test/backplane/memory/memories/memory_test.exs
  ```

  Expected: zero failures.

- [x] **Step 6: Commit canonical forget**

  ```bash
  git add \
    apps/backplane_api/lib/backplane/api/host_agent_memory_sync.ex \
    apps/backplane_api/test/backplane/api/host_agent_memory_sync_test.exs \
    apps/backplane_memory/lib/backplane/memory/memories.ex \
    apps/backplane_memory/test/backplane/memory/memories/memory_test.exs
  git commit -m "fix(memory): tombstone synced host memories"
  ```

### Task 6: Verify the Integrated PR1 Contract

**Files:**
- Review all files changed by Tasks 1–5
- Update plan checkboxes only after each RED/GREEN cycle is evidenced

- [x] **Step 1: Run scoped application suites**

  ```bash
  devenv shell -- mix test apps/backplane_host_agent/test
  devenv shell -- mix test apps/backplane_api/test
  devenv shell -- mix test apps/backplane_memory/test/backplane/memory/ingest
  devenv shell -- mix test apps/backplane_memory/test/backplane/memory/ingest_test.exs
  devenv shell -- mix test apps/backplane_memory/test/backplane/memory/events
  ```

  Expected: zero failures in every in-scope command. If an out-of-scope suite fails, list it and stop rather than fixing it.

- [x] **Step 2: Run static scoped verification**

  ```bash
  devenv shell -- mix format --check-formatted
  devenv shell -- mix compile --warnings-as-errors
  git diff --check 430b50e3..HEAD
  ```

  Expected: zero failures.

- [x] **Step 3: Verify PR1 invariants from tests**

  Confirm automated coverage for:

  - healthy recall reaches canonical Recall V2;
  - remote Recall V2 metadata and compatibility `hits` survive;
  - only transport failures enter offline mode;
  - offline mode returns provisional commands only and explicitly reports canonical history unavailable;
  - unauthorized/partition/validation/governance errors never fall back;
  - pending remember is visible before ACK;
  - ACK/canonical ID removes duplicates;
  - pending forget suppresses canonical results;
  - Hub-only `memory::*` tools remain discoverable/callable;
  - captured events cannot ACK incomplete host-private compatibility partitions or explicit conflicting authority claims;
  - source runtime/scope remain provenance, not authority;
  - host forget atomically tombstones the canonical memory and is idempotent.

- [x] **Step 4: Verify scope and untouched surfaces**

  ```bash
  git status --short
  git diff --stat 430b50e3..HEAD
  git diff --name-only 430b50e3..HEAD
  ```

  Expected: no Admin UI changes, no `host_memory.v2`, no edge revision/cursor tables, no encryption implementation, no slot/facet namespace change, no projection-coalescing work, and no unrelated baseline cleanup.

- [x] **Step 5: Request final spec and quality review**

  Review the complete branch against:

  - `docs/memory/memory-v2-implementation-audit.md` P0-01 through P0-06;
  - `docs/memory/adr-memory-space-partition.md` host-private compatibility and fail-closed ingest invariants, without claiming Stage 1 `memory_space_id` completion;
  - `docs/memory/adr-host-edge-encryption.md` production mirror gate;
  - the PR1 scope and non-goals in this plan.
