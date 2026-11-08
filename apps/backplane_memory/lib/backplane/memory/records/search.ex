defmodule Backplane.Memory.Records.Search do
  @moduledoc """
  Full-text search over `memory_records`.

  Uses `websearch_to_tsquery('simple', ...)` (which never raises on operator
  characters) OR'd with `ILIKE` matches so queries consisting only of
  operators, and CJK text without word separators, still match.
  """

  import Ecto.Query

  alias Backplane.Memory.Record

  @default_limit 10
  @max_limit 50
  @default_budget 4000
  @max_terms 10

  # The base query's first binding is always aliased `m0` by Ecto; the generated
  # tsvector column is not a schema field, so it is referenced by that alias.
  @spec search(String.t(), map()) :: [Record.t()]
  def search(query, filters \\ %{}) when is_binary(query) do
    limit = clamp(filters["limit"], @default_limit, @max_limit)
    budget = clamp(filters["token_budget"], @default_budget, :infinity)
    patterns = patterns(query)

    Record
    |> match(query, patterns)
    |> status_filter(filters["include_inactive"])
    |> filter_equal(:host_id, filters["host_id"])
    |> filter_equal(:agent_id, filters["agent_id"])
    |> filter_equal(:kind, filters["kind"])
    |> filter_subject(filters["subject"])
    |> filter_time(:since, filters["since"])
    |> filter_time(:until, filters["until"])
    |> order_by([r],
      desc:
        fragment(
          "ts_rank_cd(m0.search_tsv, websearch_to_tsquery('simple', ?))",
          ^query
        ),
      desc: r.observed_at
    )
    |> limit(^limit)
    |> repo().all()
    |> within_budget(budget)
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
