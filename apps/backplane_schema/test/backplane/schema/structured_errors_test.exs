defmodule Backplane.Schema.StructuredErrorsTest do
  use ExUnit.Case, async: true

  test "built-in validation groups use stable codes" do
    cases = [
      {:required, %{value: {:required, :integer}}, %{}},
      {:type, %{value: :integer}, %{value: "bad"}},
      {:literal, %{value: {:literal, :yes}}, %{value: :no}},
      {:enum, %{value: {:enum, [:yes, :no]}}, %{value: :maybe}},
      {:either, %{value: {:either, {:integer, :string}}}, %{value: false}},
      {:oneof, %{value: {:oneof, [:integer, :string, :boolean]}}, %{value: []}},
      {:tuple_size, %{value: {:tuple, [:integer, :string]}}, %{value: {1}}},
      {:tuple_element, %{value: {:tuple, [:integer, :string]}}, %{value: {1, false}}},
      {:coercion, %{value: {:coerce, :string, :integer}}, %{value: "not an integer"}},
      {:ref, %{value: {:ref, {String, :missing_schema}}}, %{value: 1}},
      {:multi_dispatch, %{value: {:multi, :kind, %{"ok" => %{kind: :string}}}}, %{value: %{}}},
      {:dependent, %{value: {:dependent, fn _ -> {:error, "expected type of string", []} end}},
       %{value: "x"}},
      {:custom, %{value: {:custom, fn _ -> {:error, "is required", []} end}}, %{value: "x"}}
    ]

    for {code, schema, data} <- cases do
      assert {:error, [%Backplane.Schema.Error{code: ^code}]} =
               Backplane.Schema.validate(schema, data)
    end

    assert {:error, %Backplane.Schema.Error{code: :type}} =
             Backplane.Schema.validate_schema(:unsupported_type)
  end

  test "constraint errors use their constraint names" do
    cases = [
      {:eq, {:integer, eq: 2}, 1},
      {:neq, {:integer, neq: 2}, 2},
      {:gt, {:integer, gt: 2}, 1},
      {:gte, {:integer, gte: 2}, 1},
      {:lt, {:integer, lt: 2}, 3},
      {:lte, {:integer, lte: 2}, 3},
      {:range, {:integer, range: {2, 4}}, 5},
      {:multiple_of, {:integer, multiple_of: 2}, 3},
      {:regex, {:string, regex: ~r/^a/}, "no"},
      {:min, {:string, min: 3}, "ab"},
      {:max, {:string, max: 2}, "abc"},
      {:min, {:list, :integer, min: 2}, [1]},
      {:max, {:list, :integer, max: 1}, [1, 2]},
      {:unique, {:list, :integer, unique: true}, [1, 1]}
    ]

    for {code, schema, value} <- cases do
      assert {:error, [%Backplane.Schema.Error{code: ^code}]} =
               Backplane.Schema.validate(%{value: schema}, %{value: value})
    end
  end

  test "message overrides and translation preserve the original code" do
    schema = %{age: {:integer, gte: 18, error: "must be an adult"}}

    assert {:error, [%Backplane.Schema.Error{code: :gte, message: "must be an adult"} = error]} =
             Backplane.Schema.validate(schema, %{age: 17})

    assert [%Backplane.Schema.Error{code: :gte, message: "translated"}] =
             Backplane.Schema.Error.traverse_errors([error], fn _ -> "translated" end)
  end

  test "custom and dependent callback messages are not used to infer codes" do
    custom = %{value: {:custom, fn _ -> {:error, "is required", []} end}}
    dependent = %{value: {:dependent, fn _ -> {:error, "expected type of :string", []} end}}

    assert {:error, [%Backplane.Schema.Error{code: :custom}]} =
             Backplane.Schema.validate(custom, %{value: "x"})

    assert {:error, [%Backplane.Schema.Error{code: :dependent}]} =
             Backplane.Schema.validate(dependent, %{value: "x"})
  end

  test "codes survive path updates, map conversion, and JSON encoders" do
    error = %Backplane.Schema.Error{path: [:value], key: :value, code: :type, message: "invalid"}

    assert %{code: :type, path: [:root, :value]} =
             Backplane.Schema.Error.update_error_paths(error, [:root])

    assert %{code: :type} = Backplane.Schema.Error.error_to_map(error)
    assert inspect(error) =~ "code: :type"

    if Code.ensure_loaded?(Jason) do
      assert %{"code" => "type"} = error |> Jason.encode!() |> Jason.decode!()
    end

    if Code.ensure_loaded?(JSON) do
      assert %{"code" => "type"} = error |> JSON.encode!() |> JSON.decode!()
    end
  end

  test "parent errors can remain unclassified while leaves have codes" do
    schema = %{user: %{name: {:required, :string}}}

    assert {:error,
            [
              %Backplane.Schema.Error{
                code: nil,
                errors: [%Backplane.Schema.Error{code: :required}]
              }
            ]} =
             Backplane.Schema.validate(schema, %{user: %{}})
  end

  test "list failures include their zero-based index in path and content" do
    assert {:error, %Backplane.Schema.Error{path: [1], content: %{index: 1}, code: :type}} =
             Backplane.Schema.validate({:list, :integer}, [1, "x"])

    assert {:error, [%Backplane.Schema.Error{path: [:xs, 1], content: %{index: 1}, code: :type}]} =
             Backplane.Schema.validate(%{xs: {:list, :integer}}, %{xs: [1, "x"]})
  end

  test "nested map and list errors include each index only once" do
    schema = %{items: {:list, %{name: :string}}}

    assert {:error,
            [
              %Backplane.Schema.Error{
                errors: [%Backplane.Schema.Error{path: [:items, 0, :name], content: content}]
              }
            ]} =
             Backplane.Schema.validate(schema, %{items: [%{name: 1}]})

    assert content.index == 0

    nested_list = %{items: {:list, {:list, :integer}}}

    assert {:error, [%Backplane.Schema.Error{path: [:items, 0, 1], content: %{index: 1}}]} =
             Backplane.Schema.validate(nested_list, %{items: [[1, "x"]]})
  end
end
