defmodule Backplane.Settings.Credentials do
  @moduledoc """
  Centralized encrypted credential store. All secrets in one table,
  referenced by name everywhere else.

  - `store/4` — encrypt and upsert a credential
  - `fetch/1` — decrypt and return plaintext
  - `delete/1` — remove a credential
  - `list/0` — list credentials (never returns plaintext)
  - `exists?/1` — check if credential exists
  """

  alias Backplane.Repo
  alias Backplane.Settings.Credential
  alias Backplane.Settings.Encryption

  import Ecto.Query

  @doc "Store (upsert) a credential. Encrypts the plaintext value."
  @spec store(String.t(), String.t(), String.t(), map()) :: {:ok, Credential.t()} | {:error, term()}
  def store(name, plaintext, kind, metadata \\ %{}) do
    encrypted = Encryption.encrypt(plaintext)

    case Repo.get_by(Credential, name: name) do
      nil ->
        %Credential{}
        |> Credential.changeset(%{
          name: name,
          kind: kind,
          encrypted_value: encrypted,
          metadata: metadata
        })
        |> Repo.insert()

      existing ->
        existing
        |> Credential.changeset(%{
          kind: kind,
          encrypted_value: encrypted,
          metadata: metadata
        })
        |> Repo.update()
    end
  end

  @doc "Fetch and decrypt a credential by name."
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, :not_found | :decryption_failed}
  def fetch(name) do
    case Repo.get_by(Credential, name: name) do
      nil -> {:error, :not_found}
      %Credential{encrypted_value: encrypted} -> Encryption.decrypt(encrypted)
    end
  end

  @doc "Delete a credential by name."
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(name) do
    case Repo.get_by(Credential, name: name) do
      nil -> {:error, :not_found}
      credential ->
        Repo.delete(credential)
        :ok
    end
  end

  @doc "List all credentials. Never returns plaintext values."
  @spec list() :: [map()]
  def list do
    Credential
    |> select([c], %{
      id: c.id,
      name: c.name,
      kind: c.kind,
      metadata: c.metadata,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    })
    |> order_by([c], c.name)
    |> Repo.all()
  end

  @doc "Check if a credential exists by name."
  @spec exists?(String.t()) :: boolean()
  def exists?(name) do
    Credential
    |> where([c], c.name == ^name)
    |> Repo.exists?()
  end
end
