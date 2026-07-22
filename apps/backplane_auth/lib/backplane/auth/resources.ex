defmodule Backplane.Auth.Resources do
  @moduledoc """
  Defines canonical OAuth protected resources and their resource-relative scopes.
  """

  alias Backplane.WebOrigins

  @type key :: :mcp | :v1

  @keys [:mcp, :v1]
  @identity_scopes MapSet.new(["openid", "profile", "email"])
  @local_http_hosts MapSet.new(["localhost", "127.0.0.1", "::1"])
  @operation_scope_pattern ~r/\A(?:\*|[\w-]+::(?:\*|[\w-]+))\z/
  @v1_scopes MapSet.new(["llm::models", "llm::invoke", "llm::*", "*"])

  @spec keys() :: [key()]
  def keys, do: @keys

  @spec path(key()) :: String.t()
  def path(:mcp), do: "/mcp"
  def path(:v1), do: "/v1"

  @spec uri(key()) :: String.t()
  def uri(key), do: WebOrigins.api_url(path(key))

  @spec metadata_uri(key()) :: String.t()
  def metadata_uri(key),
    do: WebOrigins.api_url("/.well-known/oauth-protected-resource/#{key}")

  @spec documentation_uri(key()) :: String.t()
  def documentation_uri(:mcp), do: WebOrigins.api_url("/docs/mcp")
  def documentation_uri(:v1), do: WebOrigins.api_url("/docs/llm")

  @spec from_uri(String.t()) :: {:ok, key()} | :error
  def from_uri(value) when is_binary(value) do
    Enum.find_value(@keys, :error, fn key -> if value == uri(key), do: {:ok, key} end)
  end

  @spec normalize_keys([term()]) :: {:ok, [key()]} | {:error, :invalid_resource}
  def normalize_keys(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_key(value) do
        {:ok, key} -> {:cont, {:ok, [key | acc]}}
        :error -> {:halt, {:error, :invalid_resource}}
      end
    end)
    |> then(fn
      {:ok, keys} -> {:ok, keys |> Enum.uniq() |> Enum.sort()}
      error -> error
    end)
  end

  @spec validate_origin([key()]) :: :ok | {:error, :https_required}
  def validate_origin([]), do: :ok

  def validate_origin(resources) when is_list(resources) do
    with {:ok, uri} <- URI.new(WebOrigins.api_base_url()),
         true <- allowed_origin?(uri) do
      :ok
    else
      _result -> {:error, :https_required}
    end
  end

  @spec valid_scope?(key(), String.t()) :: boolean()
  def valid_scope?(_key, "system::" <> _rest), do: false
  def valid_scope?(_key, scope) when scope in ["openid", "profile", "email"], do: true
  def valid_scope?(:mcp, scope), do: mcp_operation_scope?(scope)
  def valid_scope?(:v1, scope), do: MapSet.member?(@v1_scopes, scope)

  @spec operation_scope?(key(), String.t()) :: boolean()
  def operation_scope?(:mcp, scope), do: mcp_operation_scope?(scope)
  def operation_scope?(:v1, scope), do: MapSet.member?(@v1_scopes, scope)

  @spec protected_operation_scope?(String.t()) :: boolean()
  def protected_operation_scope?("system::" <> _rest), do: false
  def protected_operation_scope?(scope), do: operation_scope_name?(scope)

  @spec default_scopes(key(), [String.t()], [String.t()]) ::
          {:ok, [String.t()]} | {:error, :invalid_scope}
  def default_scopes(key, client_scopes, user_scopes) do
    user_set = MapSet.new(user_scopes)

    scopes =
      client_scopes
      |> Enum.filter(&MapSet.member?(user_set, &1))
      |> Enum.filter(&operation_scope?(key, &1))
      |> Enum.reject(&MapSet.member?(@identity_scopes, &1))
      |> Enum.uniq()
      |> Enum.sort()

    if scopes == [], do: {:error, :invalid_scope}, else: {:ok, scopes}
  end

  defp mcp_operation_scope?("system::" <> _rest), do: false
  defp mcp_operation_scope?(scope), do: operation_scope_name?(scope)

  defp operation_scope_name?(scope) when is_binary(scope),
    do: Regex.match?(@operation_scope_pattern, scope)

  defp operation_scope_name?(_scope), do: false

  defp normalize_key(key) when key in @keys, do: {:ok, key}
  defp normalize_key("mcp"), do: {:ok, :mcp}
  defp normalize_key("v1"), do: {:ok, :v1}
  defp normalize_key(_value), do: :error

  defp allowed_origin?(%URI{scheme: "https"} = uri), do: structural_origin?(uri)

  defp allowed_origin?(%URI{scheme: "http", host: host} = uri),
    do: structural_origin?(uri) and insecure_local_origin_allowed?(host)

  defp allowed_origin?(_uri), do: false

  defp structural_origin?(%URI{
         host: host,
         userinfo: nil,
         path: path,
         query: nil,
         fragment: nil
       })
       when is_binary(host) and host != "" and path in [nil, "", "/"],
       do: true

  defp structural_origin?(_uri), do: false

  defp insecure_local_origin_allowed?(host) do
    Application.get_env(:backplane_auth, :allow_insecure_resource_origins, false) and
      Application.get_env(:backplane, :env) in [:dev, :test] and
      MapSet.member?(@local_http_hosts, String.downcase(host))
  end
end
