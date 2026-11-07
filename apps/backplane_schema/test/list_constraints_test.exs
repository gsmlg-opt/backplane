defmodule Backplane.Schema.ListConstraintsTest do
  use ExUnit.Case, async: true

  describe "validate_schema/1 — list constraint shape" do
    test "accepts :list as an untyped list schema" do
      assert {:ok, :list} = Backplane.Schema.validate_schema(:list)
      assert {:ok, [1]} = Backplane.Schema.validate(:list, [1])
      assert {:error, _} = Backplane.Schema.validate(:list, :not_a_list)
    end

    test "accepts :min, :max, :unique" do
      assert {:ok, _} =
               Backplane.Schema.validate_schema({:list, :integer, [min: 1, max: 5, unique: true]})
    end

    test "rejects unknown constraint" do
      assert {:error, _} = Backplane.Schema.validate_schema({:list, :integer, [foo: 1]})
    end

    test "rejects non-keyword opts" do
      assert {:error, _} = Backplane.Schema.validate_schema({:list, :integer, [:bogus]})
    end
  end

  describe "validate/2 — :list with constraints" do
    test ":min enforced" do
      schema = %{tags: {:list, :string, [min: 2]}}
      assert {:error, [err]} = Backplane.Schema.validate(schema, %{tags: ["a"]})
      assert err.message =~ "at least 2"
      assert {:ok, _} = Backplane.Schema.validate(schema, %{tags: ["a", "b"]})
    end

    test ":max enforced" do
      schema = %{tags: {:list, :string, [max: 2]}}
      assert {:error, [err]} = Backplane.Schema.validate(schema, %{tags: ["a", "b", "c"]})
      assert err.message =~ "at most 2"
    end

    test ":unique enforced" do
      schema = %{tags: {:list, :string, [unique: true]}}
      assert {:error, [err]} = Backplane.Schema.validate(schema, %{tags: ["a", "a"]})
      assert err.message =~ "unique"
      assert {:ok, _} = Backplane.Schema.validate(schema, %{tags: ["a", "b"]})
    end

    test "still validates element types" do
      schema = %{nums: {:list, :integer, [min: 1]}}
      assert {:error, _} = Backplane.Schema.validate(schema, %{nums: ["x"]})
    end
  end

  describe "validate/2 — :multiple_of" do
    test "integer multiple_of" do
      schema = %{n: {:integer, {:multiple_of, 3}}}
      assert {:ok, _} = Backplane.Schema.validate(schema, %{n: 9})
      assert {:error, [err]} = Backplane.Schema.validate(schema, %{n: 10})
      assert err.message =~ "multiple of"
    end

    test "float multiple_of" do
      schema = %{n: {:float, {:multiple_of, 0.5}}}
      assert {:ok, _} = Backplane.Schema.validate(schema, %{n: 1.5})
      assert {:error, _} = Backplane.Schema.validate(schema, %{n: 1.3})
    end

    test "schema rejects zero divisor" do
      assert {:error, _} = Backplane.Schema.validate_schema({:integer, {:multiple_of, 0}})
    end

    test "works inside opts list" do
      schema = %{n: {:integer, [gte: 0, multiple_of: 5]}}
      assert {:ok, _} = Backplane.Schema.validate(schema, %{n: 25})
      assert {:error, _} = Backplane.Schema.validate(schema, %{n: 24})
    end
  end

  describe "to_json_schema/2 — encoder" do
    test "list constraints emit minItems/maxItems/uniqueItems" do
      assert Backplane.Schema.to_json_schema({:list, :integer, [min: 1, max: 3, unique: true]}) ==
               %{
                 "type" => "array",
                 "items" => %{"type" => "integer"},
                 "minItems" => 1,
                 "maxItems" => 3,
                 "uniqueItems" => true
               }
    end

    test "multipleOf emitted for numerics" do
      assert Backplane.Schema.to_json_schema({:integer, {:multiple_of, 5}}) == %{
               "type" => "integer",
               "multipleOf" => 5
             }

      assert Backplane.Schema.to_json_schema({:float, {:multiple_of, 0.25}}) == %{
               "type" => "number",
               "multipleOf" => 0.25
             }
    end

    test "merges with other numeric opts" do
      json = Backplane.Schema.to_json_schema({:integer, [gte: 0, multiple_of: 2]})
      assert json["type"] == "integer"
      assert json["minimum"] == 0
      assert json["multipleOf"] == 2
    end
  end

  describe "from_json_schema/1 — decoder" do
    test "decodes minItems/maxItems/uniqueItems" do
      json = %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "minItems" => 1,
        "maxItems" => 4,
        "uniqueItems" => true
      }

      assert {:ok, {:list, :string, opts}} = Backplane.Schema.from_json_schema(json)
      assert opts[:min] == 1
      assert opts[:max] == 4
      assert opts[:unique] == true
    end

    test "decodes multipleOf for integer values and integral floats only" do
      json = %{"type" => "integer", "multipleOf" => 5}

      integral_float =
        {:custom, {Backplane.Schema.JSONSchema.Decoder, :validate_integral_float, [json]}}

      assert {:ok, {:either, {{:integer, {:multiple_of, 5}}, ^integral_float}} = schema} =
               Backplane.Schema.from_json_schema(json)

      assert {:ok, 10} = Backplane.Schema.validate(schema, 10)
      assert {:ok, 10.0} = Backplane.Schema.validate(schema, 10.0)
      assert {:error, _} = Backplane.Schema.validate(schema, 7)
      assert {:error, _} = Backplane.Schema.validate(schema, 5.5)
    end

    test "plain array integer items accept integers and integral floats" do
      json = %{"type" => "array", "items" => %{"type" => "integer"}}
      assert {:ok, {:list, item_schema}} = Backplane.Schema.from_json_schema(json)
      assert item_schema == decoded_integer_schema()
      assert {:ok, [1, 2.0]} = Backplane.Schema.validate({:list, item_schema}, [1, 2.0])
      assert {:error, _} = Backplane.Schema.validate({:list, item_schema}, [1, 2.5])
    end
  end

  describe "roundtrip" do
    test "list constraints roundtrip with integer item semantics" do
      peri = {:list, :integer, [min: 1, max: 3, unique: true]}
      json = Backplane.Schema.to_json_schema(peri)

      assert {:ok, {:list, item_schema, [min: 1, max: 3, unique: true]} = decoded} =
               Backplane.Schema.from_json_schema(json)

      assert item_schema == decoded_integer_schema()
      assert {:ok, [1, 2.0]} = Backplane.Schema.validate(decoded, [1, 2.0])
      assert {:error, _} = Backplane.Schema.validate(decoded, [1, 2.5])
    end

    test "multiple_of roundtrip preserves integer-valued float semantics" do
      peri = {:integer, {:multiple_of, 5}}
      json = Backplane.Schema.to_json_schema(peri)

      assert {:ok, schema} = Backplane.Schema.from_json_schema(json)
      assert schema == decoded_integer_schema(%{"type" => "integer", "multipleOf" => 5})
      assert {:ok, 10.0} = Backplane.Schema.validate(schema, 10.0)
      assert {:error, _} = Backplane.Schema.validate(schema, 10.5)
    end
  end

  defp decoded_integer_schema(json_schema \\ %{"type" => "integer"}) do
    integer_type =
      case Map.fetch(json_schema, "multipleOf") do
        {:ok, divisor} -> {:integer, {:multiple_of, divisor}}
        :error -> :integer
      end

    {:either,
     {integer_type,
      {:custom, {Backplane.Schema.JSONSchema.Decoder, :validate_integral_float, [json_schema]}}}}
  end
end
