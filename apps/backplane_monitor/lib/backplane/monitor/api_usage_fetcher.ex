defmodule Backplane.Monitor.ApiUsageFetcher do
  @moduledoc "Resolves vaulted API keys and returns secret-free provider usage snapshots."

  alias Backplane.Monitor.{ApiAccount, ApiAccounts}
  alias Backplane.Monitor.Providers.{DeepSeek, OpenRouter}
  alias Backplane.Settings.Encryption
  alias Backplane.Settings.Credentials.Vault

  @type reason ::
          :provider_not_supported
          | :credential_not_found
          | :invalid_credential_kind
          | :invalid_credential_auth_type
          | :invalid_credential
          | :decryption_failed
          | :invalid_response
          | :request_failed
          | {:http_error, integer()}
  @type balance :: %{
          currency: String.t(),
          total_balance: String.t(),
          granted_balance: String.t() | nil,
          topped_up_balance: String.t() | nil
        }
  @type usage :: %{label: String.t(), amount: String.t(), currency: String.t()}
  @type limit :: %{
          amount: String.t() | nil,
          remaining: String.t() | nil,
          currency: String.t(),
          reset: String.t() | nil
        }
  @type data :: %{
          balances: [balance()],
          usage: [usage()],
          limit: limit() | nil,
          is_available: boolean() | nil,
          warnings: [{:account_credits, reason()}]
        }

  @spec fetch_usage(ApiAccount.t()) :: {:ok, data()} | {:error, reason()}
  def fetch_usage(%ApiAccount{provider: "openrouter"} = account) do
    with {:ok, key} <- resolve_credential(account.credential_name) do
      management_key =
        case account.management_credential_name do
          nil -> nil
          name -> resolve_credential(name)
        end

      OpenRouter.fetch(key, management_key)
    end
  end

  def fetch_usage(%ApiAccount{provider: "deepseek"} = account) do
    with {:ok, key} <- resolve_credential(account.credential_name) do
      DeepSeek.fetch(key)
    end
  end

  def fetch_usage(%ApiAccount{}), do: {:error, :provider_not_supported}

  defp resolve_credential(name) when is_binary(name) do
    case Vault.get(name) do
      nil ->
        {:error, :credential_not_found}

      %{kind: kind} when kind not in ["llm", "service"] ->
        {:error, :invalid_credential_kind}

      %{encrypted_value: encrypted} = credential ->
        if ApiAccounts.api_key_credential?(credential) do
          with {:ok, key} <- Encryption.decrypt(encrypted) do
            if key != "" and not String.match?(key, ~r/\s/),
              do: {:ok, key},
              else: {:error, :invalid_credential}
          end
        else
          {:error, :invalid_credential_auth_type}
        end
    end
  rescue
    _exception -> {:error, :decryption_failed}
  end

  defp resolve_credential(_name), do: {:error, :credential_not_found}

  @doc false
  @spec request(atom(), String.t(), String.t()) :: {:ok, map()} | {:error, reason()}
  def request(option, url, key) do
    options =
      :backplane_monitor
      |> Application.get_env(option, [])
      |> Keyword.take([:plug, :adapter])
      |> Keyword.merge(
        url: url,
        auth: {:bearer, key},
        redirect: false,
        retry: false,
        redirect_log_level: false,
        retry_log_level: false,
        finch: [
          pool_timeout: 5_000,
          receive_timeout: 10_000,
          request_timeout: 15_000,
          conn_opts: [transport_opts: [timeout: 5_000]]
        ],
        decode_body: false
      )

    case Req.get(options) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body, floats: :decimals) do
          {:ok, data} when is_map(data) -> {:ok, data}
          _other -> {:error, :invalid_response}
        end

      {:ok, %{status: 200}} ->
        {:error, :invalid_response}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _error} ->
        {:error, :request_failed}
    end
  rescue
    _exception -> {:error, :request_failed}
  catch
    :exit, _reason -> {:error, :request_failed}
  end

  @doc false
  @spec amount(term(), :number | :string) :: {:ok, String.t() | nil} | {:error, :invalid_response}
  def amount(nil, _type), do: {:ok, nil}

  def amount(value, :number) when is_integer(value), do: {:ok, Integer.to_string(value)}

  def amount(%Decimal{coef: coefficient} = value, :number) when is_integer(coefficient) do
    {:ok, Decimal.to_string(value, :normal)}
  end

  def amount(value, :string) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{coef: coefficient} = decimal, ""} when is_integer(coefficient) ->
        {:ok, Decimal.to_string(decimal, :normal)}

      _other ->
        {:error, :invalid_response}
    end
  end

  def amount(_value, _type), do: {:error, :invalid_response}
end
