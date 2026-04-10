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
  @spec delete(String.t()) :: :ok | {:error, :not_found | :delete_failed}
  def delete(name) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      credential ->
        case Repo.delete(credential) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :delete_failed}
        end
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

  @doc "Rotate a credential's secret (update only the encrypted value)."
  @spec rotate(String.t(), String.t()) :: {:ok, Credential.t()} | {:error, :not_found | term()}
  def rotate(name, new_plaintext) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      existing ->
        encrypted = Encryption.encrypt(new_plaintext)

        existing
        |> Credential.changeset(%{encrypted_value: encrypted})
        |> Repo.update()
    end
  end

  @doc "Update a credential's kind and/or metadata (not the secret)."
  @spec update(String.t(), map()) :: {:ok, Credential.t()} | {:error, :not_found | term()}
  def update(name, attrs) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      existing ->
        existing
        |> Credential.changeset(Map.take(attrs, [:kind, :metadata, "kind", "metadata"]))
        |> Repo.update()
    end
  end

  @doc """
  Get the last 4 characters of a credential's decrypted value as a hint.
  Returns `"...xxxx"` format, or `"..."` if the value is too short.
  """
  @spec fetch_hint(String.t()) :: String.t()
  def fetch_hint(name) do
    case fetch(name) do
      {:ok, plaintext} when byte_size(plaintext) >= 4 ->
        "..." <> String.slice(plaintext, -4..-1//1)

      {:ok, _} ->
        "..."

      {:error, _} ->
        "..."
    end
  end
end
