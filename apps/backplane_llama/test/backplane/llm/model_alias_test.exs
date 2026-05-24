defmodule Backplane.LLM.ModelAliasTest do
  use Backplane.DataCase, async: false

  alias Backplane.LLM.ModelAlias

  setup do
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})
    :ok
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "create/1" do
    test "valid attrs creates settings-backed alias" do
      assert {:ok, model_alias} =
               ModelAlias.create(%{
                 alias: "coding",
                 target: "smart"
               })

      assert model_alias.alias == "coding"
      assert model_alias.target == "smart"
      assert Backplane.Settings.get(ModelAlias.setting_key()) == %{"coding" => "smart"}
    end

    test "accepts legacy model attrs as target" do
      assert {:ok, model_alias} =
               ModelAlias.create(%{
                 alias: "mini",
                 model: "gpt-4o-mini"
               })

      assert model_alias.target == "gpt-4o-mini"
    end

    test "replaces an existing alias" do
      assert {:ok, _} = ModelAlias.put("coding", "smart")
      assert {:ok, model_alias} = ModelAlias.put("coding", "expert")

      assert model_alias.target == "expert"
      assert [%{alias: "coding", target: "expert"}] = ModelAlias.list()
    end

    test "rejects built-in alias names" do
      assert {:error, changeset} = ModelAlias.create(%{alias: "smart", target: "expert"})

      assert %{alias: [_ | _]} = errors_on(changeset)
    end

    test "rejects slash in alias" do
      assert {:error, changeset} =
               ModelAlias.create(%{
                 alias: "some/alias",
                 target: "smart"
               })

      assert %{alias: [_ | _]} = errors_on(changeset)
    end

    test "rejects self-referential alias" do
      assert {:error, changeset} = ModelAlias.create(%{alias: "coding", target: "coding"})

      assert %{target: [_ | _]} = errors_on(changeset)
    end
  end

  describe "delete/1" do
    test "removes the alias" do
      {:ok, model_alias} = ModelAlias.put("to-delete", "smart")

      assert {:ok, _} = ModelAlias.delete(model_alias)
      assert ModelAlias.list() == []
    end

    test "returns not found for missing alias" do
      assert {:error, :not_found} = ModelAlias.delete("missing")
    end
  end

  describe "list/0" do
    test "returns aliases ordered by alias" do
      {:ok, _} = ModelAlias.put("z-last", "expert")
      {:ok, _} = ModelAlias.put("a-first", "smart")

      assert [
               %{alias: "a-first", target: "smart"},
               %{alias: "z-last", target: "expert"}
             ] = ModelAlias.list()
    end
  end

  describe "get/1 and target_for/1" do
    test "returns configured alias target" do
      {:ok, _} = ModelAlias.put("coding", "smart")

      assert %ModelAlias{alias: "coding", target: "smart"} = ModelAlias.get("coding")
      assert ModelAlias.target_for("coding") == "smart"
      assert ModelAlias.get("missing") == nil
      assert ModelAlias.target_for("missing") == nil
    end
  end
end
