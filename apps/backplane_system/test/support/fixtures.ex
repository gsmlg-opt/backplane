defmodule BackplaneSystem.Fixtures do
  @moduledoc false

  alias Backplane.Clients.Client
  alias Backplane.Repo

  def insert_client(overrides \\ []) do
    name = Keyword.get(overrides, :name, "test-client-#{System.unique_integer([:positive])}")

    token =
      Keyword.get(
        overrides,
        :token,
        "bp_test_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
      )

    attrs = %{
      name: name,
      token_hash: Bcrypt.hash_pwd_salt(token),
      scopes: Keyword.get(overrides, :scopes, ["*"]),
      active: Keyword.get(overrides, :active, true),
      metadata: Keyword.get(overrides, :metadata, %{})
    }

    client =
      %Client{}
      |> Client.changeset(attrs)
      |> Repo.insert!()

    {client, token}
  end
end
