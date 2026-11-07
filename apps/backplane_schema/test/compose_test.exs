defmodule Backplane.Schema.ComposeTest do
  use ExUnit.Case, async: true

  import Backplane.Schema

  doctest Backplane.Schema, only: [merge: 2, select: 2, except: 2]

  defschema(:user, %{
    name: {:required, :string},
    age: :integer
  })

  describe "merge/2" do
    test "combines disjoint fields" do
      assert {:ok, %{name: :string, age: :integer}} =
               Backplane.Schema.merge(%{name: :string}, %{age: :integer})
    end

    test "right side wins on overlapping field" do
      assert {:ok, %{name: :atom}} = Backplane.Schema.merge(%{name: :string}, %{name: :atom})
    end

    test "deep merges nested maps preserving fields from both sides" do
      left = %{user: %{name: :string, profile: %{bio: :string}}}
      right = %{user: %{age: :integer, profile: %{avatar: :string}}}

      assert {:ok,
              %{
                user: %{
                  name: :string,
                  age: :integer,
                  profile: %{bio: :string, avatar: :string}
                }
              }} = Backplane.Schema.merge(left, right)
    end

    test "right side wins on conflicting nested leaf" do
      left = %{user: %{name: :string}}
      right = %{user: %{name: {:required, :string}}}

      assert {:ok, %{user: %{name: {:required, :string}}}} = Backplane.Schema.merge(left, right)
    end

    test "type tuples are never merged structurally" do
      left = %{tags: {:list, :string}}
      right = %{tags: {:list, :integer}}

      assert {:ok, %{tags: {:list, :integer}}} = Backplane.Schema.merge(left, right)
    end

    test "merged schema validates data correctly" do
      {:ok, base} = Backplane.Schema.merge(%{name: {:required, :string}}, %{age: :integer})
      {:ok, schema} = Backplane.Schema.merge(base, %{admin: :boolean})

      assert {:ok, %{name: "Zoey", age: 30, admin: true}} =
               Backplane.Schema.validate(schema, %{name: "Zoey", age: 30, admin: true})

      assert {:error, _} = Backplane.Schema.validate(schema, %{age: 30})
    end

    test "round-trips a defschema through merge" do
      {:ok, extended} =
        Backplane.Schema.merge(get_schema(:user), %{role: {:enum, [:admin, :member]}})

      data = %{name: "Zoey", age: 30, role: :admin}
      assert {:ok, ^data} = Backplane.Schema.validate(extended, data)
      assert {:error, _} = Backplane.Schema.validate(extended, %{name: "Zoey", role: :root})
    end

    test "returns error when the merged result is invalid" do
      assert {:error, _} = Backplane.Schema.merge(%{name: :string}, %{age: :str})
    end

    test "raises ArgumentError on non-map schemas" do
      assert_raise ArgumentError, fn -> Backplane.Schema.merge(:string, %{}) end
      assert_raise ArgumentError, fn -> Backplane.Schema.merge(%{}, :string) end
    end
  end

  describe "select/2" do
    test "keeps only the given keys" do
      schema = %{name: :string, age: :integer, email: :string}

      assert {:ok, %{name: :string, email: :string}} =
               Backplane.Schema.select(schema, [:name, :email])
    end

    test "ignores keys not present in the schema" do
      assert {:ok, %{name: :string}} =
               Backplane.Schema.select(%{name: :string}, [:name, :missing])
    end

    test "empty selection returns an empty schema" do
      assert {:ok, schema} = Backplane.Schema.select(%{name: :string}, [])
      assert map_size(schema) == 0
    end

    test "selected schema validates data correctly" do
      {:ok, public} = Backplane.Schema.select(%{name: :string, password: :string}, [:name])

      assert {:ok, %{name: "Zoey"}} =
               Backplane.Schema.validate(public, %{name: "Zoey", password: "secret"})
    end

    test "raises ArgumentError on non-map schemas" do
      assert_raise ArgumentError, fn -> Backplane.Schema.select(:string, [:name]) end
    end
  end

  describe "except/2" do
    test "drops the given keys" do
      schema = %{name: :string, age: :integer, email: :string}

      assert {:ok, %{name: :string, age: :integer}} = Backplane.Schema.except(schema, [:email])
    end

    test "ignores keys not present in the schema" do
      assert {:ok, %{name: :string}} = Backplane.Schema.except(%{name: :string}, [:missing])
    end

    test "raises ArgumentError on non-map schemas" do
      assert_raise ArgumentError, fn -> Backplane.Schema.except(:string, [:name]) end
    end
  end
end
