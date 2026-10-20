defmodule Backplane.Config.ClientSeedsTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Clients

  setup do
    previous = Application.get_env(:backplane, :client_seeds)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:backplane, :client_seeds),
        else: Application.put_env(:backplane, :client_seeds, previous)
    end)

    :ok
  end

  test "metadata seed startup is idempotent and never issues or rotates credentials" do
    Application.put_env(:backplane, :client_seeds, [%{name: "seed", scopes: ["docs::*"]}])
    assert :ok = BackplaneSystem.Application.seed_clients()
    client = Clients.get_client_by_name("seed")
    assert is_nil(client.token_digest)

    assert :ok = BackplaneSystem.Application.seed_clients()
    assert Clients.get_client_by_name("seed").id == client.id
    assert {:ok, issued, token} = Clients.rotate_client_token(client)
    assert :ok = BackplaneSystem.Application.seed_clients()
    seeded = Clients.get_client_by_name("seed")
    assert seeded.id == issued.id
    assert seeded.token_digest == issued.token_digest
    assert {:ok, authenticated} = Clients.verify_token(token)
    assert authenticated.id == seeded.id
  end

  test "invalid seed aborts startup with a bounded secret-free error" do
    Application.put_env(:backplane, :client_seeds, [%{name: "", scopes: ["*"]}])
    assert {:error, :invalid_client_seed} = BackplaneSystem.Application.seed_clients()
  end
end
