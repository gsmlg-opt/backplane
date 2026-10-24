defmodule Backplane.MemorySourceContractTest do
  use ExUnit.Case, async: true
  alias Backplane.MemorySourceContract, as: Contract

  defp mutation do
    %{
      "protocol" => "memory_sources.v1",
      "source" => %{
        "integration" => "hermes",
        "installation_id" => "b6b8672a-74a0-4df7-b533-ec0a99f49df8",
        "profile_id" => "default",
        "target" => "memory"
      },
      "event_id" => "2699493c-6347-4138-baba-8b09393a8500",
      "entry_id" => "34aa960d-50c9-4086-ad8e-06f9a340b03f",
      "revision" => 1,
      "operation" => "upsert",
      "content" => "完整来源",
      "type" => "semantic",
      "occurred_at" => "2026-10-24T01:00:00Z",
      "provenance" => %{"session_id" => "real-session", "author" => %{"name" => "user"}}
    }
  end

  test "preserves complete immutable payload and empty-content withdrawal" do
    args = mutation()
    assert {:ok, ^args} = Contract.validate("source_mutate", args)
    withdrawal = args |> Map.put("operation", "withdraw") |> Map.delete("content")
    assert {:ok, ^withdrawal} = Contract.validate("source_mutate", withdrawal)

    assert {:error, :invalid_arguments} =
             Contract.validate("source_mutate", Map.put(withdrawal, "content", ""))
  end

  test "trusted authority cannot be injected even in author or repository metadata" do
    for args <- [
          Map.put(mutation(), "host_id", "attacker"),
          put_in(mutation(), ["provenance", "author", "host_id"], "attacker"),
          put_in(mutation(), ["source", "scope"], "other")
        ] do
      assert {:error, :invalid_arguments} = Contract.validate("source_mutate", args)
    end
  end

  test "portable hash uses sorted keys compact UTF8 and rejects unsupported numbers" do
    assert {:ok, ~s({"a":["记忆",true,1],"z":null})} =
             Contract.encode(%{"z" => nil, "a" => ["记忆", true, 1]})

    assert Contract.digest(%{"a" => 1, "b" => 2}) == Contract.digest(%{"b" => 2, "a" => 1})
    assert {:error, :not_json_safe} = Contract.encode(%{"score" => 0.2})
  end

  test "complete empty snapshot is distinct from an omitted page or invalid manifest" do
    args =
      Map.take(mutation(), ~w(protocol source event_id))
      |> Map.merge(%{
        "phase" => "begin",
        "reconciliation_id" => "2699493c-6347-4138-baba-8b09393a8500",
        "revision" => 2,
        "page_count" => 0,
        "entry_count" => 0,
        "snapshot_hash" => Contract.digest([])
      })

    assert {:ok, ^args} = Contract.validate("source_reconcile", args)

    assert {:error, :invalid_arguments} =
             Contract.validate("source_reconcile", Map.put(args, "entry_count", 1))
  end
end
