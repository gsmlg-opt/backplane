defmodule Backplane.Diagnostics.Evidence do
  @moduledoc "Immutable, bounded evidence selected by Diagnostics for an issue."

  alias Backplane.Diagnostics.Evidence.Source
  alias Backplane.Diagnostics.Events.Event
  alias Backplane.Diagnostics.Retention
  alias Backplane.Diagnostics.Sources.Source, as: RegisteredSource
  alias Backplane.DiagnosticsClient.{Canonical, Redaction}
  alias Backplane.Repo

  import Ecto.Query

  @max_events 8
  @max_bytes 12 * 1024
  @code_limit 3

  defmodule Bundle do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_evidence_bundles" do
      field :issue_id, :id
      field :digest, :string
      field :payload, :map
      field :expires_at, :utc_datetime_usec
      field :expired_at, :utc_datetime_usec
      field :inserted_at, :utc_datetime_usec
    end
  end

  @doc "Freezes the selected issue context and records stable reference and digest identifiers."
  def freeze(issue, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    retention = Retention.policy(opts)

    events =
      issue
      |> Map.get(:events, [])
      |> Enum.take(@max_events)
      |> Enum.filter(&usable?(&1, retention, now))

    refs = events |> Enum.map(&event_reference/1) |> append_code(opts) |> bounded_refs()

    payload = %{
      "issue_id" => issue.id,
      "category" => enum_text(issue[:category]),
      "severity" => enum_text(issue[:severity]),
      "occurrence_ids" => issue |> Map.get(:occurrence_ids, []) |> Enum.take(@max_events),
      "references" => refs
    }

    with {:ok, bytes} <- Canonical.encode(payload) do
      expires_at =
        events
        |> Enum.map(&Retention.event_expires_at(&1, retention))
        |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn ->
          DateTime.add(now, retention.exception_days, :day)
        end)

      persist(issue.id, Canonical.digest(bytes), payload, expires_at, now)
    end
  end

  @doc "Reads a bundle only while its evidence remains available."
  def load(bundle_id, now \\ DateTime.utc_now()) do
    case Repo.get(Bundle, bundle_id, log: false) do
      nil ->
        {:error, :not_found}

      %Bundle{payload: nil} ->
        {:error, :evidence_expired}

      %Bundle{} = bundle ->
        if DateTime.after?(bundle.expires_at, now) and live_references?(bundle.payload, now),
          do: {:ok, bundle},
          else: {:error, :evidence_expired}
    end
  end

  def expired?(bundle_id, now \\ DateTime.utc_now()) do
    not match?({:ok, %Bundle{}}, load(bundle_id, now))
  end

  @doc "Looks up an internal ID within its authorized bundle."
  def fetch(bundle_id, reference_id)
      when is_binary(reference_id) and byte_size(reference_id) <= 48 do
    with {:ok, bundle} <- load(bundle_id) do
      case find_ref(bundle.payload, reference_id) do
        nil -> {:error, :not_found}
        observation -> {:ok, observation}
      end
    end
  end

  def fetch(_bundle, _ref), do: {:error, :not_found}

  @doc false
  def find_ref(%{"references" => refs}, id), do: Enum.find(refs, &(&1["id"] == id))

  defp persist(issue_id, digest, body, expires_at, now) do
    Repo.insert!(
      %Bundle{
        issue_id: issue_id,
        digest: digest,
        payload: body,
        expires_at: expires_at,
        inserted_at: now
      },
      conflict_target: [:issue_id, :digest],
      on_conflict: :nothing,
      log: false
    )

    {:ok, Repo.get_by!(Bundle, [issue_id: issue_id, digest: digest], log: false)}
  end

  defp usable?(%Event{body: %{} = body} = event, retention, now) do
    get_in(body, ["quality", "evidence_expired"]) != true and
      DateTime.after?(Retention.event_expires_at(event, retention), now)
  end

  defp usable?(_, _, _), do: false

  defp live_references?(%{"references" => refs}, now) do
    ids =
      for %{"kind" => "event", "id" => "event:" <> id} <- refs,
          {value, ""} <- [Integer.parse(id)],
          value in 1..9_223_372_036_854_775_807,
          do: value

    case ids do
      [] ->
        true

      _ ->
        policy = Retention.policy()

        events =
          Event
          |> where([event], event.id in ^ids)
          |> select([event], struct(event, [:id, :event_type, :received_at]))
          |> select_merge([event], %{
            body:
              fragment(
                "jsonb_build_object('quality', ? -> 'quality', 'result', ? -> 'result')",
                event.body,
                event.body
              )
          })
          |> Repo.all(log: false)

        length(events) == length(ids) and Enum.all?(events, &usable?(&1, policy, now))
    end
  end

  defp event_reference(%Event{} = event) do
    projected = Redaction.project(event.body)
    evidence = Map.get(projected, "evidence", %{})
    exception = Map.get(evidence, "exception", %{})

    %{
      "id" => "event:#{event.id}",
      "kind" => "event",
      "event_id" => event.event_id,
      "source_id" => event.source_id,
      "event_type" => event.event_type,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "subject" => projected["subject"],
      "correlation" => projected["correlation"],
      "version" => projected["version"],
      "result" => projected["result"],
      "quality" => projected["quality"],
      "exception" => Map.update(exception, "stack", [], &Enum.take(&1, 5)),
      "breadcrumbs" => evidence |> Map.get("breadcrumbs", []) |> Enum.take(3),
      "measurements" => evidence |> Map.get("measurements", []) |> Enum.take(4),
      "contract" => evidence["contract"]
    }
  end

  defp append_code(refs, opts) do
    repositories =
      Keyword.get_lazy(opts, :repositories, fn ->
        Application.get_env(:backplane_diagnostics, :source_repositories, %{})
      end)

    candidates =
      for %{
            "id" => id,
            "source_id" => source_id,
            "version" => %{"repository" => repository, "git_sha" => sha},
            "exception" => %{"stack" => frames}
          } <- refs,
          %{"file" => path, "line" => line} <- frames,
          do: {id, source_id, repository, sha, path, line}

    registrations = registered_repositories(candidates)

    sources =
      candidates
      |> Enum.uniq_by(fn {_id, source_id, repo, sha, path, line} ->
        {source_id, repo, sha, path, line}
      end)
      |> Enum.take(@code_limit)
      |> Enum.with_index(1)
      |> Enum.map(fn {{event_ref, source_id, repo, sha, path, line}, index} ->
        sources = if registrations[source_id] == repo, do: repositories, else: %{}

        detail =
          case Source.read(sources, repo, sha, path, line) do
            {:ok, text} -> text
            {:error, status} -> %{"status" => Atom.to_string(status)}
          end

        Map.merge(
          %{
            "id" => "source:#{index}",
            "kind" => "source",
            "event_ref" => event_ref,
            "repository" => repo,
            "sha" => sha,
            "path" => path
          },
          detail
        )
      end)

    # Keep the first representative event and its code context before adding supporting samples.
    case refs do
      [primary | others] -> [primary | sources] ++ others
      [] -> []
    end
  end

  defp registered_repositories([]), do: %{}

  defp registered_repositories(candidates) do
    ids = Enum.map(candidates, &elem(&1, 1)) |> Enum.uniq()

    RegisteredSource
    |> where([source], source.id in ^ids)
    |> select([source], {source.id, source.repository})
    |> Repo.all(log: false)
    |> Map.new()
  end

  defp bounded_refs(refs) do
    {kept, _used} =
      Enum.reduce(refs, {[], 0}, fn ref, {acc, used} ->
        size = byte_size(JSON.encode!(ref)) + 1
        if used + size <= @max_bytes, do: {[ref | acc], used + size}, else: {acc, used}
      end)

    kept = Enum.reverse(kept)
    known = MapSet.new(kept, & &1["id"])
    Enum.filter(kept, &(&1["kind"] != "source" or MapSet.member?(known, &1["event_ref"])))
  end

  defp enum_text(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp enum_text(value) when is_binary(value), do: Redaction.summary(value, 64)
  defp enum_text(_), do: nil
end
