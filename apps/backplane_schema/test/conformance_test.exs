defmodule Backplane.Schema.ConformanceTest do
  use ExUnit.Case, async: true

  @schema %{
    name: {:required, {:string, [min: 2, max: 12]}},
    age: {:required, {:integer, [gte: 18, lte: 120]}},
    status: {:enum, ["ready", "paused"]},
    scores: {:list, :integer, [min: 1, max: 4]},
    profile: %{
      nickname: {:required, :string},
      active: {:required, :boolean}
    }
  }

  @valid_data %{
    name: "Ada",
    age: 37,
    status: "ready",
    scores: [3, 5],
    profile: %{nickname: "ada", active: true}
  }

  @acceptance_corpus [
    {@valid_data, true},
    {Map.delete(@valid_data, :name), false},
    {Map.put(@valid_data, :age, 17), false},
    {Map.put(@valid_data, :status, "unknown"), false},
    {Map.put(@valid_data, :scores, [3, "five"]), false},
    {put_in(@valid_data, [:profile, :nickname], nil), false}
  ]

  test "core and JSON Schema agree on the shared corpus" do
    assert {:ok, json_schema} =
             @schema
             |> Backplane.Schema.to_json_schema()
             |> Backplane.Schema.from_json_schema(keys: :atoms)

    for {data, expected?} <- @acceptance_corpus do
      assert accepted?(Backplane.Schema.validate(@schema, data)) == expected?
      assert accepted?(Backplane.Schema.validate(json_schema, data)) == expected?
    end
  end

  test "additional object keys retain their schema-valued validation" do
    schema = %{
      metadata: {:schema, %{label: {:required, :string}}, {:additional_keys, :integer}}
    }

    valid = %{metadata: %{label: "release", revision: 3}}
    invalid = %{metadata: %{label: "release", revision: "three"}}

    assert {:ok, json_schema} =
             schema
             |> Backplane.Schema.to_json_schema()
             |> Backplane.Schema.from_json_schema(keys: :atoms)

    for candidate <- [schema, json_schema] do
      assert {:ok, _} = Backplane.Schema.validate(candidate, valid)
      assert {:error, _} = Backplane.Schema.validate(candidate, invalid)
    end
  end

  test "coerced list elements preserve unchanged values beside converted values" do
    schema = %{values: {:list, {:coerce, :string, :integer}}}

    assert {:ok, %{values: [1, 2, 3, 4]}} =
             Backplane.Schema.validate(schema, %{values: [1, "2", 3, "4"]})
  end

  test "transformed list elements preserve values unchanged by the transform" do
    schema = %{values: {:list, {:string, {:transform, &String.trim/1}}}}

    assert {:ok, %{values: ["first", "middle", "last"]}} =
             Backplane.Schema.validate(schema, %{values: [" first", "middle", "last "]})
  end

  test "coercion has expected core decode boundary behavior" do
    schema = %{age: {:coerce, :string, {:integer, {:gte, 18}}}}
    valid = %{"age" => "21"}
    invalid = %{"age" => "17"}

    assert {:ok, %{age: 21}} = Backplane.Schema.decode(schema, valid)
    assert {:error, _} = Backplane.Schema.decode(schema, invalid)
  end

  defp accepted?({:ok, _}), do: true
  defp accepted?({:error, _}), do: false
end
