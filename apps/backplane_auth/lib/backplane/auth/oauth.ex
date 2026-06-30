defmodule Backplane.Auth.OAuth do
  @moduledoc "OAuth client and scope management for Backplane Auth."

  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.Repo
  alias Boruta.Ecto.Admin
  alias Boruta.Ecto.{Client, Scope}

  @supported_grant_types ["authorization_code", "refresh_token", "revoke", "introspect"]

  def create_scope(attrs) when is_map(attrs) do
    attrs
    |> normalize_scope_attrs()
    |> Admin.create_scope()
  end

  def get_scope(name) when is_binary(name) do
    Repo.get_by(Scope, name: String.trim(name))
  end

  def list_scopes do
    Scope
    |> order_by(:name)
    |> Repo.all()
  end

  def create_client(attrs) when is_map(attrs) do
    attrs = normalize_client_attrs(attrs)

    with :ok <- validate_client_attrs(attrs),
         {:ok, scopes} <- ensure_scopes(attrs.scopes),
         {:ok, client} <- Admin.create_client(to_boruta_client_attrs(attrs, scopes)) do
      client = Repo.preload(client, :authorized_scopes)

      if client.confidential do
        {:ok, %{client: client, secret: client.secret}}
      else
        {:ok, client}
      end
    end
  end

  def rotate_client_secret(%Client{} = client) do
    with {:ok, client} <- Admin.regenerate_client_secret(client) do
      {:ok, %{client: client, secret: client.secret}}
    end
  end

  def disable_client(%Client{} = client) do
    metadata = Map.put(client.metadata || %{}, "disabled", true)
    Admin.update_client(client, %{metadata: metadata})
  end

  def list_clients do
    Admin.list_clients()
    |> Enum.sort_by(&String.downcase(&1.name || ""))
  end

  def get_client(id) when is_binary(id) do
    Client
    |> Repo.get(id)
    |> case do
      nil -> nil
      client -> Repo.preload(client, :authorized_scopes)
    end
  end

  def assign_client_scopes(%Client{} = client, scope_names) when is_list(scope_names) do
    with {:ok, scopes} <- ensure_scopes(scope_names) do
      Admin.update_client(client, %{authorized_scopes: Enum.map(scopes, &%{id: &1.id})})
    end
  end

  def validate_redirect_uri(%Client{redirect_uris: redirect_uris}, redirect_uri)
      when is_binary(redirect_uri) do
    if redirect_uri in redirect_uris do
      :ok
    else
      {:error, :invalid_redirect_uri}
    end
  end

  defp normalize_scope_attrs(attrs) do
    attrs
    |> atomize_keys()
    |> Map.update(:name, nil, &normalize_scope_name/1)
    |> Map.put_new(:public, true)
  end

  defp normalize_client_attrs(attrs) do
    attrs = atomize_keys(attrs)
    public? = Map.get(attrs, :public, false)
    confidential? = Map.get(attrs, :confidential, not public?)

    %{
      id: Map.get(attrs, :id),
      name: Map.get(attrs, :name),
      redirect_uris: Map.get(attrs, :redirect_uris, []),
      scopes: Map.get(attrs, :scopes, Map.get(attrs, :allowed_scopes, [])),
      confidential: confidential?,
      pkce: Map.get(attrs, :pkce, false),
      access_token_ttl: Map.get(attrs, :access_token_ttl, 3_600),
      authorization_code_ttl: Map.get(attrs, :authorization_code_ttl, 60),
      refresh_token_ttl: Map.get(attrs, :refresh_token_ttl, 2_592_000),
      id_token_ttl: Map.get(attrs, :id_token_ttl, 3_600),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  defp validate_client_attrs(%{confidential: false, pkce: false}) do
    {:error, client_error(:pkce, "must be enabled for public clients")}
  end

  defp validate_client_attrs(%{redirect_uris: redirect_uris}) do
    if Enum.any?(redirect_uris, &wildcard_redirect_uri?/1) do
      {:error, client_error(:redirect_uris, "must not contain wildcard hosts")}
    else
      :ok
    end
  end

  defp to_boruta_client_attrs(attrs, scopes) do
    attrs
    |> Map.take([
      :id,
      :name,
      :redirect_uris,
      :confidential,
      :pkce,
      :access_token_ttl,
      :authorization_code_ttl,
      :refresh_token_ttl,
      :id_token_ttl,
      :metadata
    ])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.merge(%{
      authorize_scope: true,
      public_refresh_token: true,
      public_revoke: true,
      supported_grant_types: @supported_grant_types,
      token_endpoint_auth_methods: ["client_secret_basic", "client_secret_post"],
      id_token_signature_alg: "RS256",
      authorized_scopes: Enum.map(scopes, &%{id: &1.id})
    })
  end

  defp ensure_scopes(scope_names) do
    scope_names
    |> Enum.map(&normalize_scope_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, scopes} ->
      case get_scope(name) || create_scope!(name) do
        %Scope{} = scope -> {:cont, {:ok, [scope | scopes]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, scopes} -> {:ok, Enum.reverse(scopes)}
      error -> error
    end
  end

  defp create_scope!(name) do
    case create_scope(%{name: name, label: name, public: true}) do
      {:ok, scope} -> scope
      error -> error
    end
  end

  defp client_error(field, message) do
    %Client{}
    |> change()
    |> add_error(field, message)
  end

  defp wildcard_redirect_uri?(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:host)
    |> case do
      nil -> false
      host -> String.contains?(host, "*")
    end
  end

  defp normalize_scope_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_scope_name(name), do: name

  defp atomize_keys(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, String.to_atom(key), value)
    end)
  end
end
