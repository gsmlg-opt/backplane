defmodule Backplane.McpProtocol.Client.Authorization.CredentialStore do
  @moduledoc """
  Facade for persisted OAuth client credentials bound to an exact issuer.

  Applications must configure a secure adapter that encrypts credentials at
  rest or stores them in a dedicated secret manager:

      config :backplane_mcp_protocol, :authorization_credential_store,
        adapter: MyApp.OAuthCredentialStore

  The facade does not keep credentials in application configuration, ETS, a
  process, or environment variables. Adapter configuration contains only
  connection and routing options; the adapter owns durable secure storage.
  """

  alias Backplane.McpProtocol.Client.Authorization

  @config_key :authorization_credential_store

  @type key :: {issuer :: String.t(), client_id :: String.t()}
  @type credentials :: map()
  @type adapter_opts :: keyword()
  @type error :: {:error, term()}

  @doc """
  Fetches credentials for an exact `{issuer, client_id}` key.
  """
  @callback fetch(key(), adapter_opts()) :: {:ok, credentials()} | error()

  @doc """
  Persists credentials for an exact `{issuer, client_id}` key.
  """
  @callback put(key(), credentials(), adapter_opts()) :: :ok | error()

  @doc """
  Fetches credentials through the configured secure adapter.

  Tests and embedded callers may inject a store configuration with the
  `:store` option. Production callers normally use the two-argument form.
  """
  @spec fetch(String.t(), String.t(), keyword()) :: {:ok, credentials()} | error()
  def fetch(issuer, client_id, opts \\ []) do
    with {:ok, key} <- credential_key(issuer, client_id),
         {:ok, adapter, adapter_opts} <- adapter(:fetch, 2, opts) do
      adapter.fetch(key, adapter_opts)
    end
  end

  @doc """
  Persists credentials through the configured secure adapter.
  """
  @spec put(String.t(), String.t(), credentials(), keyword()) :: :ok | error()
  def put(issuer, client_id, credentials, opts \\ []) when is_map(credentials) do
    with {:ok, key} <- credential_key(issuer, client_id),
         {:ok, adapter, adapter_opts} <- adapter(:put, 3, opts) do
      adapter.put(key, credentials, adapter_opts)
    end
  end

  defp credential_key(issuer, client_id)
       when is_binary(issuer) and issuer != "" and is_binary(client_id) and client_id != "" do
    {:ok, Authorization.credential_key(issuer, client_id)}
  end

  defp credential_key(_issuer, _client_id), do: {:error, :invalid_credential_key}

  defp adapter(callback, arity, opts) do
    case store_config(opts) do
      nil ->
        {:error, :credential_store_not_configured}

      config when is_list(config) ->
        adapter = Keyword.get(config, :adapter)

        if is_atom(adapter) and Code.ensure_loaded?(adapter) and
             function_exported?(adapter, callback, arity) do
          {:ok, adapter, Keyword.delete(config, :adapter)}
        else
          {:error, :credential_store_unavailable}
        end

      _invalid ->
        {:error, :credential_store_unavailable}
    end
  end

  defp store_config(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, config} -> config
      :error -> Application.get_env(:backplane_mcp_protocol, @config_key)
    end
  end
end
