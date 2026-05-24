defmodule Backplane.Proxy.AuthInjector do
  @moduledoc """
  Single call site for credential-to-header injection.

  Resolves a named credential and prepends the appropriate authentication
  header based on the configured auth scheme. Used by both HTTP and SSE
  upstream transports.

  Credentials are resolved per-request and never cached in process state.
  """

  alias Backplane.Settings.Credentials

  @spec inject(
          headers :: [{String.t(), String.t()}],
          auth_scheme :: String.t() | nil,
          auth_header_name :: String.t() | nil,
          credential_name :: String.t() | nil
        ) :: {:ok, [{String.t(), String.t()}]} | {:error, :credential_unavailable}

  def inject(headers, nil, _auth_header_name, _credential_name), do: {:ok, headers}
  def inject(headers, "none", _auth_header_name, _credential_name), do: {:ok, headers}

  def inject(headers, "bearer", _auth_header_name, credential_name) do
    with {:ok, secret} <- fetch_credential(credential_name) do
      {:ok, [{"authorization", "Bearer #{secret}"} | headers]}
    end
  end

  def inject(headers, "x_api_key", _auth_header_name, credential_name) do
    with {:ok, secret} <- fetch_credential(credential_name) do
      {:ok, [{"x-api-key", secret} | headers]}
    end
  end

  def inject(headers, "custom_header", auth_header_name, credential_name) do
    with {:ok, secret} <- fetch_credential(credential_name) do
      {:ok, [{auth_header_name, secret} | headers]}
    end
  end

  defp fetch_credential(name) do
    case Credentials.fetch(name) do
      {:ok, secret} -> {:ok, secret}
      {:error, _} -> {:error, :credential_unavailable}
    end
  end
end
