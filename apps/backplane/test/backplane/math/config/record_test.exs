defmodule Backplane.Math.Config.RecordTest do
  use Backplane.DataCase, async: true

  alias Backplane.Math.Config.Record

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "accepts valid attrs" do
      changeset =
        Record.changeset(%Record{}, %{
          enabled: true,
          timeout_default_ms: 3_000,
          max_expr_nodes: 5_000,
          timeout_per_tool: %{"evaluate" => 1_000}
        })

      assert changeset.valid?
    end

    test "rejects non-positive timeout_default_ms" do
      changeset = Record.changeset(%Record{}, %{timeout_default_ms: 0})
      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).timeout_default_ms
    end

    test "rejects unknown units_system" do
      changeset = Record.changeset(%Record{}, %{units_system: "cubits"})
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).units_system
    end
  end

  describe "defaults/0" do
    test "returns a Record struct populated with PRD defaults" do
      record = Record.defaults()
      assert record.enabled == true
      assert record.sympy_enabled == false
      assert record.timeout_default_ms == 5_000
      assert record.max_expr_nodes == 10_000
      assert record.max_matrix_dim == 512
      assert record.units_system == "si"
    end
  end
end
