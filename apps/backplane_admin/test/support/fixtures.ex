defmodule Backplane.Admin.Fixtures do
  @moduledoc false

  def insert_client(overrides \\ []) do
    attrs = %{
      name: Keyword.get(overrides, :name, "test-client-#{System.unique_integer([:positive])}"),
      scopes: Keyword.get(overrides, :scopes, ["*"]),
      active: Keyword.get(overrides, :active, true),
      metadata: Keyword.get(overrides, :metadata, %{})
    }

    {:ok, client, token} = Backplane.Clients.issue_client(attrs)
    {client, token}
  end
end
