defmodule Backplane.Clients.ClientTest do
  use Backplane.DataCase, async: true

  alias Backplane.Clients.Client

  @valid_attrs %{
    name: "test-client",
    token_hash: "$2b$12$somehash",
    scopes: ["docs::*", "git::*"]
  }

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset" do
    test "valid with name, token_hash, scopes" do
      changeset = Client.changeset(%Client{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires name uniqueness" do
      %Client{}
      |> Client.changeset(@valid_attrs)
      |> Repo.insert!()

      {:error, changeset} =
        %Client{}
        |> Client.changeset(%{@valid_attrs | name: "test-client"})
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "validates scope format" do
      valid_scopes = ["*", "docs::*", "docs::query-docs", "git::repo-tree"]

      for scope <- valid_scopes do
        changeset = Client.changeset(%Client{}, %{@valid_attrs | scopes: [scope]})
        assert changeset.valid?, "expected scope #{inspect(scope)} to be valid"
      end

      invalid_scopes = ["", "docs", "docs:", "docs::", "docs::*::extra", "::foo", "no spaces"]

      for scope <- invalid_scopes do
        changeset = Client.changeset(%Client{}, %{@valid_attrs | scopes: [scope]})
        refute changeset.valid?, "expected scope #{inspect(scope)} to be invalid"
        assert %{scopes: [_]} = errors_on(changeset)
      end
    end

    test "rejects empty scopes list" do
      changeset = Client.changeset(%Client{}, %{@valid_attrs | scopes: []})
      refute changeset.valid?
      assert %{scopes: ["must not be empty"]} = errors_on(changeset)
    end

    test "defaults active to true" do
      changeset = Client.changeset(%Client{}, @valid_attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :active) == true
    end
  end
end
