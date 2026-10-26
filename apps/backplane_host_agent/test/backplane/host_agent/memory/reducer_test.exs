defmodule Backplane.HostAgent.Memory.ReducerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.Reducer

  test "hashes content as lowercase sha256 hex" do
    assert Reducer.content_hash("remember this") ==
             "8699bdec86f342226a646ca6d61f17cbb024e26a896384d827f46215c1a4bd70"
  end

  test "resolves bound scope and rejects caller scope drift" do
    config = %{bound_scope: "proj_local"}

    assert {:ok, "proj_local"} = Reducer.resolve_scope(%{}, config)
    assert {:ok, "proj_local"} = Reducer.resolve_scope(%{"scope" => "proj_local"}, config)
    assert {:error, :invalid_scope} = Reducer.resolve_scope(%{"scope" => "other"}, config)
  end

  test "validates required and optional trimmed values without accepting non-strings" do
    assert {:ok, "note"} = Reducer.required_string(%{"content" => "  note  "}, "content")
    assert {:ok, "note"} = Reducer.required_string(%{content: "note"}, "content")

    assert {:error, {:invalid_args, "content is required"}} =
             Reducer.required_string(%{"content" => "   "}, "content")

    assert {:error, {:invalid_args, "content is required"}} =
             Reducer.required_string(%{"content" => 42}, "content")

    assert Reducer.optional_string(%{"scope" => "  project  "}, "scope") == "project"
    assert Reducer.optional_string(%{}, "scope") == nil
    assert Reducer.value(%{offset: 2}, "offset", 0) == 2
    assert Reducer.value(%{}, "offset", 0) == 0
  end

  test "JSON helpers preserve slot values and contain malformed input" do
    value = %{"items" => [1, true, nil, %{"nested" => "text"}]}
    assert {:ok, json} = Reducer.encode_json(value)
    assert Reducer.decode_json(json, :fallback) == value
    assert Reducer.decode_json("{invalid", :fallback) == :fallback
    assert Reducer.decode_json(nil, :fallback) == :fallback
    assert Reducer.decode_json(42, :fallback) == :fallback

    assert {:error, {:invalid_args, "value must be JSON encodable"}} =
             Reducer.encode_json(self())
  end
end
