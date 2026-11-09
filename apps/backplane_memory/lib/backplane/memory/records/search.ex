defmodule Backplane.Memory.Records.Search do
  @moduledoc """
  Full-text search over `memory_records`.

  Uses `websearch_to_tsquery('simple', ...)` (which never raises on operator
  characters) OR'd with `ILIKE` matches so queries consisting only of
  operators, and CJK text without word separators, still match.
  """

  import Ecto.Query

  alias Backplane.Memory.Embedding.{CircuitBreaker, Client}
  alias Backplane.Memory.Record

  require Logger

  @default_limit 10
  @max_limit 50
  @default_budget 4000
  @max_terms 10

  @leg_size 50
  @rrf_k 60

  # The base query's first binding is always aliased `m0` by Ecto; the generated
  # tsvector column is not a schema field, so it is referenced by that alias.
  @spec search(String.t(), map()) :: [Record.t()]
  def search(query, filters \\ %{}) when is_binary(query) do
    limit = clamp(filters["limit"], @default_limit, @max_limit)
    budget = clamp(filters["token_budget"], @default_budget, :infinity)

    query
    |> hybrid_or_text(filters, limit)
    |> within_budget(budget)
  end

  defp hybrid_or_text(query, filters, limit) do
    case vector_ids(query, filters) do
      {:ok, vector_ids} ->
        fuse(vector_ids, text_ids(query, filters), filters, limit)

      :unavailable ->
        query |> text_query(filters) |> limit(^limit) |> repo().all()
    end
  end

  # Shared filter pipeline for both retrieval legs.
  defp filtered(filters) do
    Record
    |> status_filter(filters["include_inactive"])
    |> filter_equal(:host_id, filters["host_id"])
    |> filter_equal(:agent_id, filters["agent_id"])
    |> filter_equal(:kind, filters["kind"])
    |> filter_subject(filters["subject"])
    |> filter_time(:since, filters["since"])
    |> filter_time(:until, filters["until"])
  end

  defp text_query(query, filters) do
    filters
    |> filtered()
    |> match(query, patterns(query))
    |> order_by([r],
      desc:
        fragment(
          "ts_rank_cd(m0.search_tsv, websearch_to_tsquery('simple', ?))",
          ^query
        ),
      desc: r.observed_at
    )
  end

  defp text_ids(query, filters) do
    query |> text_query(filters) |> limit(^@leg_size) |> select([r], r.id) |> repo().all()
  end

  # Embeds the query and returns the nearest ids; any problem yields :unavailable so the
  # caller silently uses full-text only (the embed worker carries the warning). A blank
  # query is never embedded and never touches the circuit breaker.
  defp vector_ids(query, filters) do
    if String.trim(query) == "", do: :unavailable, else: nearest_ids(query, filters)
  end

  defp nearest_ids(query, filters) do
    with true <- Client.configured?(),
         true <- CircuitBreaker.allow_request?(),
         {:ok, [vector]} <- embed_query(query) do
      CircuitBreaker.record_success()

      ids =
        filters
        |> filtered()
        |> where([r], not is_nil(r.embedding))
        |> order_by([r], asc: fragment("? <=> ?", r.embedding, ^Pgvector.new(vector)))
        |> limit(^@leg_size)
        |> select([r], r.id)
        |> repo().all()

      {:ok, ids}
    else
      false ->
        :unavailable

      {:error, reason} ->
        CircuitBreaker.record_failure()
        Logger.debug("memory search: embedding unavailable, using full-text: #{inspect(reason)}")
        :unavailable
    end
  end

  defp embed_query(query) do
    req_options = Application.get_env(:backplane_memory, :embedding_req_options, [])
    Client.embed([query], :query, req_options: req_options)
  end

  defp fuse(vector_ids, text_ids, filters, limit) do
    scores =
      [vector_ids, text_ids]
      |> Enum.flat_map(fn ids -> Enum.with_index(ids, 1) end)
      |> Enum.reduce(%{}, fn {id, rank}, acc ->
        Map.update(acc, id, 1 / (@rrf_k + rank), &(&1 + 1 / (@rrf_k + rank)))
      end)

    top = scores |> Enum.sort_by(fn {_id, score} -> -score end) |> Enum.take(limit)
    ids = Enum.map(top, &elem(&1, 0))
    by_id = filters |> filtered() |> where([r], r.id in ^ids) |> repo().all() |> Map.new(&{&1.id, &1})

    ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  @doc false
  def clamp(nil, default, _max), do: default
  def clamp(n, _default, :infinity) when is_integer(n) and n > 0, do: n
  def clamp(n, _default, max) when is_integer(n) and n > 0, do: min(n, max)

  def clamp(n, _default, _max),
    do: raise(ArgumentError, "invalid positive integer: #{inspect(n)}")

  @doc false
  def filter_equal(q, _field, nil), do: q
  def filter_equal(q, field, value), do: where(q, [r], field(r, ^field) == ^value)

  @doc false
  def filter_time(q, _which, nil), do: q
  def filter_time(q, :since, v), do: where(q, [r], r.observed_at >= ^parse_time!(v))
  def filter_time(q, :until, v), do: where(q, [r], r.observed_at <= ^parse_time!(v))

  defp parse_time!(%DateTime{} = dt), do: dt

  defp parse_time!(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} ->
        dt

      {:error, reason} ->
        raise ArgumentError, "invalid ISO 8601 timestamp #{inspect(v)}: #{reason}"
    end
  end

  defp status_filter(q, true), do: q
  defp status_filter(q, _), do: where(q, [r], r.status == "active")

  defp filter_subject(q, nil), do: q

  defp filter_subject(_q, subject) when not is_binary(subject),
    do: raise(ArgumentError, "invalid subject")

  defp filter_subject(q, subject) do
    key = subject |> String.trim() |> String.downcase()
    where(q, [r], ^key in r.subject_keys)
  end

  defp match(q, query, patterns) do
    where(
      q,
      [r],
      fragment("m0.search_tsv @@ websearch_to_tsquery('simple', ?)", ^query) or
        fragment("? ILIKE ANY(?)", r.content, type(^patterns, {:array, :string})) or
        fragment("coalesce(?, '') ILIKE ANY(?)", r.title, type(^patterns, {:array, :string})) or
        fragment(
          "memory_records_immutable_join(?) ILIKE ANY(?)",
          r.subject_keys,
          type(^patterns, {:array, :string})
        )
    )
  end

  defp patterns(query) do
    trimmed = String.trim(query)

    terms =
      trimmed
      |> String.split(~r/\s+/, trim: true)
      |> Enum.filter(&(String.length(&1) >= 2))
      |> Enum.take(@max_terms)

    [trimmed | terms]
    |> Enum.filter(&(String.length(&1) >= 2))
    |> Enum.uniq()
    |> Enum.map(&("%" <> escape_like(&1) <> "%"))
  end

  defp escape_like(s), do: String.replace(s, ~r/[\\%_]/, "\\\\\\0")

  defp within_budget(records, budget) do
    {kept, _} =
      Enum.reduce_while(records, {[], 0}, fn r, {acc, used} ->
        cost = div(String.length(r.content), 3)

        if acc == [] or used + cost <= budget,
          do: {:cont, {[r | acc], used + cost}},
          else: {:halt, {acc, used}}
      end)

    Enum.reverse(kept)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
