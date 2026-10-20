defmodule Backplane.Clients.ClientTest do
  use BackplaneSystem.DataCase, async: true

  alias Backplane.Clients.Client

  @valid_attrs %{
    name: "test-client",
    scopes: ["docs::*", "git::*"]
  }

  describe "changeset" do
    test "credential fields are rejected and removed from params" do
      for key <- ~w(token token_hash token_digest scheme credential_scheme) do
        attrs = Map.new(@valid_attrs, fn {key, value} -> {to_string(key), value} end)
        changeset = Client.changeset(%Client{}, Map.put(attrs, key, "secret-value"))
        refute changeset.valid?
        refute inspect(changeset) =~ "secret-value"
        refute Map.has_key?(changeset.params, key)
      end
    end

    test "digest is redacted from inspected clients" do
      digest = :crypto.strong_rand_bytes(32)
      client = %Client{token_digest: digest}
      refute inspect(client) =~ inspect(digest)
      refute inspect(client) =~ "token_digest:"
    end

    test "valid with name and scopes" do
      changeset = Client.changeset(%Client{}, @valid_attrs)
      assert changeset.valid?
    end

    test "database permits null credentials and enforces digest length and uniqueness" do
      for name <- ["unissued-one", "unissued-two"] do
        assert {:ok, _} =
                 %Client{} |> Client.changeset(%{@valid_attrs | name: name}) |> Repo.insert()
      end

      digest = :crypto.strong_rand_bytes(32)

      assert {:ok, _} =
               %Client{}
               |> Client.changeset(%{@valid_attrs | name: "issued"})
               |> Ecto.Changeset.put_change(:token_digest, digest)
               |> Repo.insert()

      assert {:error, duplicate} =
               %Client{}
               |> Client.changeset(%{@valid_attrs | name: "duplicate"})
               |> Ecto.Changeset.put_change(:token_digest, digest)
               |> Repo.insert()

      assert %{token_digest: ["has already been taken"]} = errors_on(duplicate)

      assert {:error, malformed} =
               %Client{}
               |> Client.changeset(%{@valid_attrs | name: "malformed"})
               |> Ecto.Changeset.put_change(:token_digest, <<1, 2, 3>>)
               |> Repo.insert()

      assert %{token_digest: [_]} = errors_on(malformed)
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
