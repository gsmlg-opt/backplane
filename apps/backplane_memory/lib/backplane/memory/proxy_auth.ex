defmodule Backplane.Memory.ProxyAuth do
  @moduledoc "Resolves the Memory gateway resource bearer from a named service credential."

  alias Backplane.Settings
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  def authorize(options) do
    case Settings.get("memory.proxy_credential") do
      value when value in [nil, ""] -> {:ok, options}
      name when is_binary(name) -> authorize_credential(String.trim(name), options)
      _ -> {:error, :proxy_credential_unavailable}
    end
  end

  defp authorize_credential("", options), do: {:ok, options}

  defp authorize_credential(name, options) do
    with %{kind: "service", metadata: metadata} <- Vault.get(name),
         true <- (metadata || %{})["auth_type"] in [nil, "api_key"],
         {:ok, token} when is_binary(token) and token != "" <- Credentials.fetch(name) do
      {:ok, Keyword.put(options, :auth, {:bearer, token})}
    else
      _ -> {:error, :proxy_credential_unavailable}
    end
  end
end
