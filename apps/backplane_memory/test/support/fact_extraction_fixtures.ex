defmodule Backplane.Memory.FactExtractionFixtures do
  @moduledoc false

  import Ecto.Query

  def proposals(facts, bundle) do
    Enum.map(facts, fn statement ->
      unit =
        Enum.find(bundle["assertion_units"], &(&1["text"] == statement)) ||
          hd(bundle["assertion_units"])

      event = Enum.find(bundle["events"], &(&1["id"] == unit["event_id"]))
      word = unit["text"] |> String.split() |> hd()

      %{
        "statement" => statement,
        "subject" => %{
          "kind" => if(event["role"] == "user", do: "speaker", else: "entity"),
          "text" => if(event["role"] == "user", do: "user", else: word),
          "citation" => 0
        },
        "property" => %{"text" => word, "citation" => 0},
        "value" => %{"text" => statement, "citation" => 0},
        "semantic_scope" => %{"kind" => "unspecified"},
        "citations" => [%{"event_id" => event["id"], "quote" => unit["text"]}],
        "correction_of" => []
      }
    end)
  end

  # These owning tests control semantic assessment; pure contract and HTTP tests
  # separately cover rejection. This helper never bypasses the worker validator.
  def assessment(facts) do
    %{
      "empty_supported" => facts == [],
      "verdicts" =>
        Enum.with_index(facts, fn _, index ->
          Map.new(
            ~w(subject property_value scope current_correction durable statement_equivalent self_contained),
            &{&1, "supported"}
          )
          |> Map.put("index", index)
        end)
    }
  end

  def link_summary!(summary, texts \\ nil) do
    repo = Application.fetch_env!(:backplane_memory, :repo)
    now = DateTime.utc_now()
    stream_id = "fact-fixture:" <> summary.id

    source_sequence =
      (repo.one(
         from(event in Backplane.Memory.Events.Event,
           where: event.host_id == ^summary.host_id and event.session_id == ^summary.session_id,
           select: max(event.source_sequence)
         )
       ) || 0) + 1

    attrs =
      Map.take(Map.from_struct(summary), [
        :memory_space_id,
        :host_id,
        :source_client_id,
        :scope,
        :namespace,
        :session_id,
        :agent_id,
        :project
      ])

    repo.insert!(
      struct(
        Backplane.Memory.Events.Stream,
        Map.merge(attrs, %{stream_id: stream_id, client_id: "host:" <> summary.host_id})
      )
    )

    (texts || [summary.content])
    |> Enum.with_index()
    |> Enum.each(fn {text, index} ->
      event =
        repo.insert!(
          struct(
            Backplane.Memory.Events.Event,
            Map.merge(attrs, %{
              id: Ecto.UUID.generate(),
              stream_id: stream_id,
              sequence: index + 1,
              source_sequence: source_sequence + index,
              client_id: "host:" <> summary.host_id,
              event_type: "agent.prompt.submitted",
              role: "user",
              actor_type: "user",
              content: text,
              schema_version: 1,
              payload: %{"message" => text},
              payload_hash: Base.encode16(:crypto.hash(:sha256, text), case: :lower),
              occurred_at: now,
              inserted_at: now,
              captured_at: now
            })
          )
        )

      repo.insert!(%Backplane.Memory.Summaries.SourceEvent{
        summary_id: summary.id,
        event_id: event.id,
        host_id: summary.host_id,
        session_id: summary.session_id,
        inserted_at: now
      })
    end)

    summary
  end

  def source_texts(summary) do
    Application.fetch_env!(:backplane_memory, :repo).all(
      from(link in Backplane.Memory.Summaries.SourceEvent,
        join: event in Backplane.Memory.Events.Event,
        on: event.id == link.event_id,
        where: link.summary_id == ^summary.id,
        order_by: event.sequence,
        select: event.content
      )
    )
  end
end
