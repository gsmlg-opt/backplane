defmodule Backplane.DiagnosticsClient.ContractTest do
  use ExUnit.Case, async: true

  alias Backplane.DiagnosticsClient.{Canonical, Envelope, Receipt}

  @fixtures Path.expand("../../../docs/diagnostics/protocol/v1", __DIR__)

  setup do
    event = read_json("event.json")
    {:ok, bytes, digest} = Envelope.seal(event)
    %{event: event, bytes: bytes, digest: digest, item: Receipt.entry(event, digest)}
  end

  test "matches the interoperable schema, byte and SHA-256 fixtures", context do
    assert Envelope.schema() == read_json("event.schema.json")
    assert Canonical.version() == 1
    assert context.bytes == File.read!(Path.join(@fixtures, "event.canonical.json"))
    assert context.digest == String.trim(File.read!(Path.join(@fixtures, "event.sha256")))

    batch = Receipt.batch(:local, "batch-a", [context.item])
    assert {:ok, encoded} = Receipt.encode_batch(batch)
    assert {:ok, "batch-a", [item]} = Receipt.decode_batch(encoded, :local)
    assert {:ok, context.event, context.bytes, context.digest} == Receipt.validate_entry(item)
    assert {:error, :unsupported_schema} = Receipt.decode_batch(encoded, :remote)
  end

  test "canonicalization preserves array order and rejects invalid JSON values" do
    assert {:ok, ~s({"a":["é",null,false,"\\n"],"z":1})} =
             Canonical.encode(%{"z" => 1, "a" => ["é", nil, false, "\n"]})

    for invalid <- [
          :some_atom,
          %{atom_key: true},
          1.1,
          9_007_199_254_740_992,
          <<255>>,
          Enum.reduce(1..14, 0, fn _, acc -> [acc] end)
        ] do
      assert {:error, :invalid_json} = Canonical.encode(invalid)
    end

    assert {:error, :event_too_large} = Canonical.encode([String.duplicate("a", 64 * 1024)])
  end

  test "rejects unknown or overlong fields without interning any external strings", %{
    event: event
  } do
    new_key = "diagnostics_unknown_#{System.unique_integer([:positive])}"
    assert {:error, :invalid_event} = Envelope.validate(Map.put(event, new_key, "value"))
    assert_raise ArgumentError, fn -> String.to_existing_atom(new_key) end

    for {key, value} <- [
          {"source_id", String.duplicate("界", 43)},
          {"source_id", "source\0id"},
          {"source_sequence", 0},
          {"source_sequence", 9_007_199_254_740_992},
          {"occurred_at", "2026-02-31T03:04:05Z"},
          {"event_type", new_key},
          {"duration_us", -1},
          {"evidence", %{"exception" => %{"stack" => [%{"file" => "lib/../secret"}]}}},
          {"evidence", %{"references" => List.duplicate("reference", 9)}},
          {"correlation", %{"trace_id" => String.duplicate("0", 32)}}
        ] do
      assert {:error, :invalid_event} = Envelope.validate(Map.put(event, key, value)), key
    end

    assert {:error, :unsupported_schema} = Envelope.validate(%{event | "schema_version" => 2})
  end

  test "rejects ambiguous framing and retains bad entries for individual rejection", %{item: item} do
    assert {:error, :invalid_batch} =
             Receipt.decode_batch(
               ~s({"protocol": "diagnostics.v1", "protocol": "diagnostics.v1"}),
               :local
             )

    assert {:error, :batch_too_large} =
             Receipt.validate_batch(
               Receipt.batch(:local, "batch-a", List.duplicate(item, 101)),
               :local
             )

    assert {:error, :batch_too_large} =
             Receipt.decode_batch(String.duplicate(" ", 512 * 1024 + 1), :local)

    bad = Map.put(item, "digest", String.duplicate("a", 64))
    batch = Receipt.batch(:local, "batch-a", [bad, nil, item])
    assert {:ok, "batch-a", [^bad, nil, ^item]} = Receipt.validate_batch(batch, :local)
    assert {:error, :digest_mismatch} = Receipt.validate_entry(bad)
    assert {:error, :invalid_event} = Receipt.validate_entry(nil)
  end

  test "reconciles only unique members with matching IDs, digests, and confirmation level",
       context do
    [first, second, third, fourth] =
      for id <- ~w(a b c d) do
        event = %{context.event | "event_id" => id}
        {:ok, _, digest} = Envelope.seal(event)
        Receipt.entry(event, digest)
      end

    second_result = Receipt.result(second, "duplicate")

    response =
      Receipt.response(:remote, "batch-a", [
        Receipt.result(first, "stored"),
        Map.put(second_result, "event_id", "unknown"),
        Map.put(Receipt.result(third, "stored"), "digest", context.digest),
        second_result,
        Receipt.result(first, "identity_conflict", :source_sequence_conflict)
      ])

    sent = [first, second, third, fourth]
    assert %{"b" => second_result} == Receipt.reconcile(response, :remote, "batch-a", sent)
    assert %{} == Receipt.reconcile(response, :local, "batch-a", sent)
    assert %{} == Receipt.reconcile(response, :remote, "wrong-batch", sent)
  end

  defp read_json(filename),
    do: @fixtures |> Path.join(filename) |> File.read!() |> Formata.JSON.decode!()
end
