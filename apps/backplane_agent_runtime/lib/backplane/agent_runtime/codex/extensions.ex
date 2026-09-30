defmodule Backplane.AgentRuntime.Codex.Extensions do
  @moduledoc """
  Scoped, ephemeral reference backends for Codex stateful extensions.

  This module intentionally does not claim restart durability.  A host can
  replace the state with a durable adapter later without changing the scope,
  revision, or digest contracts exposed here.
  """

  alias Backplane.AgentRuntime.{Error, Outbox}

  @max_page 100
  @collections [:memories, :notes, :goals, :history]

  @spec new(keyword()) :: map()
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    requested = Keyword.get(opts, :max_page, @max_page)

    max_page =
      if is_integer(requested) and requested > 0, do: min(requested, @max_page), else: @max_page

    %{
      mode: :ephemeral,
      max_page: max_page,
      next_id: 1,
      memories: %{},
      notes: %{},
      goals: %{},
      history: %{},
      skills: %{},
      subscriptions: %{},
      boards: %{},
      deliveries: %{},
      published: %{}
    }
  end

  def new(_opts), do: new([])

  @spec capabilities() :: map()
  def capabilities do
    %{
      mode: :ephemeral,
      durable: false,
      restart_recovery: false,
      namespaces: ~w(memory notes goals history skills agent_message_board)a
    }
  end

  @spec descriptors() :: [map()]
  def descriptors do
    Enum.map(
      ["memory", "notes", "goals", "history", "skills", "agent-message-board"],
      fn namespace ->
        %{
          namespace: namespace,
          name: "list",
          input: %{type: "object"},
          output: %{type: "object"},
          scope: :caller_run,
          availability: :reference
        }
      end
    )
  end

  @spec memory_create(map(), map(), map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def memory_create(state, scope, attrs), do: create_record(state, :memories, scope, attrs)
  @spec note_create(map(), map(), map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def note_create(state, scope, attrs), do: create_record(state, :notes, scope, attrs)
  @spec goal_create(map(), map(), map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def goal_create(state, scope, attrs), do: create_record(state, :goals, scope, attrs)

  @spec history_append(map(), map(), map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def history_append(state, scope, attrs), do: create_record(state, :history, scope, attrs)

  @spec read(map(), atom(), map(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def read(state, collection, scope, id) when collection in @collections and is_binary(id) do
    with :ok <- valid_scope(scope),
         {:ok, record} <- fetch_record(state, collection, id),
         :ok <- same_scope(record.scope, scope) do
      {:ok, record}
    end
  end

  def read(_state, _collection, _scope, _id), do: {:error, Error.new(:validation, "invalid read")}

  @spec list(map(), atom(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list(state, collection, scope, opts \\ [])

  def list(state, collection, scope, opts) when collection in @collections do
    with :ok <- valid_scope(scope),
         {:ok, cursor, limit} <- page_args(state, opts) do
      records =
        state
        |> Map.fetch!(collection)
        |> Map.values()
        |> Enum.filter(&same_scope?(&1.scope, scope))

      page = records |> Enum.sort_by(& &1.id) |> Enum.drop(cursor) |> Enum.take(limit)

      {:ok,
       %{
         items: page,
         next_cursor: if(cursor + length(page) < length(records), do: cursor + length(page))
       }}
    end
  end

  def list(_state, _collection, _scope, _opts),
    do: {:error, Error.new(:validation, "invalid collection")}

  @spec search(map(), atom(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def search(state, collection, scope, query, opts \\ [])

  def search(state, collection, scope, query, opts)
      when collection in @collections and is_binary(query) do
    with :ok <- valid_scope(scope),
         {:ok, cursor, limit} <- page_args(state, opts) do
      q = String.downcase(query)

      records =
        state
        |> Map.fetch!(collection)
        |> Map.values()
        |> Enum.filter(&same_scope?(&1.scope, scope))

      matches = Enum.filter(records, &String.contains?(inspect(&1.data) |> String.downcase(), q))
      page = matches |> Enum.sort_by(& &1.id) |> Enum.drop(cursor) |> Enum.take(limit)

      {:ok,
       %{
         items: page,
         next_cursor: if(cursor + length(page) < length(matches), do: cursor + length(page))
       }}
    end
  end

  def search(_state, _collection, _scope, _query, _opts),
    do: {:error, Error.new(:validation, "invalid search")}

  @spec update(map(), atom(), map(), String.t(), non_neg_integer(), map()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def update(state, collection, scope, id, expected_revision, attrs)
      when collection in @collections and is_binary(id) and is_integer(expected_revision) and
             is_map(attrs) do
    with :ok <- valid_scope(scope),
         {:ok, record} <- fetch_record(state, collection, id),
         :ok <- same_scope(record.scope, scope),
         :ok <- expected_revision(record, expected_revision) do
      updated = %{record | data: attrs, revision: record.revision + 1}
      {:ok, put_in(state, [collection, id], updated), updated}
    end
  end

  def update(_state, _collection, _scope, _id, _revision, _attrs),
    do: {:error, Error.new(:validation, "invalid update")}

  @spec skill_publish(map(), map(), map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def skill_publish(state, scope, attrs) when is_map(attrs) do
    with :ok <- valid_scope(scope),
         {:ok, name} <- required(attrs, :name),
         {:ok, content} <- required(attrs, :content),
         true <- is_binary(content) and byte_size(content) <= 262_144 do
      digest = digest(content)
      revision = Map.get(state.skills, {scope_key(scope), name}, %{revision: 0}).revision + 1

      skill = %{
        name: name,
        content: content,
        digest: digest,
        revision: revision,
        bundle: Map.get(attrs, :bundle, "bundle_" <> digest),
        provenance: Map.get(attrs, :provenance, %{}),
        scope: scope
      }

      {:ok, put_in(state, [:skills, {scope_key(scope), name}], skill), skill}
    else
      false -> {:error, Error.new(:resource_conflict, "skill content exceeds bound")}
      error -> error
    end
  end

  @spec skill_read(map(), map(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def skill_read(state, scope, name, revision, expected_digest)
      when is_binary(name) and is_integer(revision) and is_binary(expected_digest) do
    with :ok <- valid_scope(scope),
         {:ok, skill} <- fetch_skill(state, scope, name),
         true <- skill.revision == revision,
         true <- skill.digest == expected_digest do
      {:ok, skill}
    else
      false -> {:error, Error.new(:resource_conflict, "skill revision or digest conflict")}
      error -> error
    end
  end

  @spec subscribe(map(), map(), String.t()) :: {:ok, map(), map()} | {:error, Error.t()}
  def subscribe(state, scope, board) when is_binary(board) do
    with :ok <- valid_scope(scope) do
      id = "sub_" <> unique_id()
      sub = %{id: id, board: board, scope: scope}
      {:ok, put_in(state, [:subscriptions, id], sub), sub}
    end
  end

  @spec unsubscribe(map(), map(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def unsubscribe(state, scope, id) when is_binary(id) do
    with :ok <- valid_scope(scope),
         {:ok, sub} <-
           Map.fetch(state.subscriptions, id) |> fetch_error("subscription not found"),
         :ok <- same_scope(sub.scope, scope) do
      {:ok,
       %{
         state
         | subscriptions: Map.delete(state.subscriptions, id),
           deliveries: Map.delete(state.deliveries, id)
       }}
    end
  end

  @spec publish(map(), map(), String.t(), map(), String.t()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def publish(state, scope, board, payload, message_id)
      when is_binary(board) and is_map(payload) and is_binary(message_id) do
    with :ok <- valid_scope(scope),
         {:ok, outbox} <- Outbox.new(10_000),
         {:ok, _outbox, _receipt} <- Outbox.submit(outbox, message_id, payload) do
      publication_key = {scope_key(scope), board, message_id}

      if Map.has_key?(state.published, publication_key) do
        {:ok, state, %{status: :duplicate, message_id: message_id, delivered: 0}}
      else
        subs =
          state.subscriptions
          |> Map.values()
          |> Enum.filter(&(&1.board == board and same_scope?(&1.scope, scope)))

        {deliveries, _} =
          Enum.reduce(subs, {state.deliveries, []}, fn sub, {acc, _} ->
            key = {sub.id, message_id}

            if Map.has_key?(acc, key),
              do: {acc, []},
              else: {Map.put(acc, key, %{message_id: message_id, payload: payload}), []}
          end)

        {:ok,
         %{
           state
           | deliveries: deliveries,
             published: Map.put(state.published, publication_key, true)
         }, %{status: :published, message_id: message_id, delivered: length(subs)}}
      end
    end
  end

  @spec poll(map(), map(), String.t(), non_neg_integer()) :: {:ok, [map()]} | {:error, Error.t()}
  def poll(state, scope, subscription_id, limit \\ 50) when is_binary(subscription_id) do
    with :ok <- valid_scope(scope),
         {:ok, sub} <-
           Map.fetch(state.subscriptions, subscription_id)
           |> fetch_error("subscription not found"),
         :ok <- same_scope(sub.scope, scope),
         true <- is_integer(limit) and limit > 0 and limit <= @max_page do
      {:ok,
       state.deliveries
       |> Enum.filter(fn {{id, _}, _} -> id == subscription_id end)
       |> Enum.take(limit)
       |> Enum.map(fn {key, value} -> Map.put(value, :delivery_key, key) end)}
    else
      false -> {:error, Error.new(:validation, "invalid delivery limit")}
      error -> error
    end
  end

  @spec ack(map(), map(), String.t(), {String.t(), String.t()}) ::
          {:ok, map()} | {:error, Error.t()}
  def ack(state, scope, subscription_id, key) do
    with :ok <- valid_scope(scope),
         {:ok, sub} <-
           Map.fetch(state.subscriptions, subscription_id)
           |> fetch_error("subscription not found"),
         :ok <- same_scope(sub.scope, scope),
         true <- valid_delivery_key?(key, subscription_id) do
      {:ok, %{state | deliveries: Map.delete(state.deliveries, key)}}
    else
      false -> {:error, Error.new(:forbidden, "delivery does not belong to subscription")}
      error -> error
    end
  end

  defp create_record(state, collection, scope, attrs) when is_map(attrs) do
    with :ok <- valid_scope(scope) do
      id = "" <> Atom.to_string(collection) <> "_" <> Integer.to_string(state.next_id)
      record = %{id: id, scope: scope, revision: 1, data: attrs}

      updated =
        state
        |> Map.put(collection, Map.put(Map.fetch!(state, collection), id, record))
        |> Map.put(:next_id, state.next_id + 1)

      {:ok, updated, record}
    end
  end

  defp create_record(_state, _collection, _scope, _attrs),
    do: {:error, Error.new(:validation, "record must be a map")}

  defp valid_scope(scope) when is_map(scope) do
    if Enum.all?(
         [:host_id, :caller_id, :run_id, :project_id],
         &(is_binary(Map.get(scope, &1)) and Map.get(scope, &1) != "")
       ),
       do: :ok,
       else: {:error, Error.new(:forbidden, "complete host/caller/run/project scope required")}
  end

  defp valid_scope(_), do: {:error, Error.new(:forbidden, "scope required")}

  defp same_scope(a, b),
    do:
      if(scope_key(a) == scope_key(b),
        do: :ok,
        else: {:error, Error.new(:forbidden, "cross-scope access denied")}
      )

  defp same_scope?(a, b), do: scope_key(a) == scope_key(b)

  defp valid_delivery_key?({subscription_id, message_id}, subscription_id)
       when is_binary(message_id),
       do: true

  defp valid_delivery_key?(_, _), do: false

  defp scope_key(scope),
    do: Enum.map([:host_id, :caller_id, :run_id, :project_id], &Map.get(scope, &1))

  defp fetch_record(state, collection, id),
    do: Map.fetch(state |> Map.fetch!(collection), id) |> fetch_error("record not found")

  defp fetch_skill(state, scope, name),
    do: Map.fetch(state.skills, {scope_key(scope), name}) |> fetch_error("skill not found")

  defp fetch_error({:ok, value}, _), do: {:ok, value}
  defp fetch_error(:error, message), do: {:error, Error.new(:not_found, message)}
  defp expected_revision(%{revision: revision}, revision), do: :ok

  defp expected_revision(%{revision: revision}, expected),
    do:
      {:error,
       Error.new(:resource_conflict, "revision conflict",
         details: %{expected: expected, current: revision}
       )}

  defp page_args(state, opts) do
    cursor = Keyword.get(opts, :cursor, 0)
    limit = Keyword.get(opts, :limit, min(state.max_page, @max_page))

    if is_integer(cursor) and cursor >= 0 and is_integer(limit) and limit > 0 and
         limit <= state.max_page,
       do: {:ok, cursor, limit},
       else: {:error, Error.new(:validation, "invalid pagination")}
  end

  defp required(map, key),
    do:
      if(is_binary(Map.get(map, key)) and Map.get(map, key) != "",
        do: {:ok, Map.get(map, key)},
        else: {:error, Error.new(:validation, "#{key} is required")}
      )

  defp digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  defp unique_id, do: :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
end
