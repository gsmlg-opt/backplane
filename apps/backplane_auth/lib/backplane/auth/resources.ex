defmodule Backplane.Auth.Resources do
  alias Backplane.WebOrigins

  @type key :: :mcp | :v1

  @keys [:mcp, :v1]
  @identity_scopes MapSet.new(["openid", "profile", "email"])
  @v1_scopes MapSet.new(["llm::models", "llm::invoke", "llm::*", "*"])

  def keys, do: @keys

  def path(:mcp), do: "/mcp"
  def path(:v1), do: "/v1"

  def uri(key), do: WebOrigins.api_url(path(key))

  def metadata_uri(key),
    do: WebOrigins.api_url("/.well-known/oauth-protected-resource/#{key}")

  def documentation_uri(:mcp), do: WebOrigins.api_url("/docs/mcp")
  def documentation_uri(:v1), do: WebOrigins.api_url("/docs/llm")

  def from_uri(value) when is_binary(value) do
    Enum.find_value(@keys, :error, fn key -> if value == uri(key), do: {:ok, key} end)
  end

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

  def validate_origin([]), do: :ok

  def validate_origin(resources) when is_list(resources) do
    uri = URI.parse(WebOrigins.api_base_url())

    if uri.scheme == "https" or insecure_local_origin_allowed?() do
      :ok
    else
      {:error, :https_required}
    end
  end

  def valid_scope?(_key, "system::" <> _rest), do: false
  def valid_scope?(_key, scope) when scope in ["openid", "profile", "email"], do: true
  def valid_scope?(:mcp, scope), do: mcp_operation_scope?(scope)
  def valid_scope?(:v1, scope), do: MapSet.member?(@v1_scopes, scope)

  def operation_scope?(:mcp, scope), do: mcp_operation_scope?(scope)
  def operation_scope?(:v1, scope), do: MapSet.member?(@v1_scopes, scope)

  def protected_operation_scope?("*"), do: true
  def protected_operation_scope?("system::" <> _rest), do: false

  def protected_operation_scope?(scope),
    do: Regex.match?(~r/^[^:]+::(?:\*|[^:]+)$/, scope)

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

  defp mcp_operation_scope?("*"), do: true
  defp mcp_operation_scope?("system::" <> _rest), do: false
  defp mcp_operation_scope?(scope), do: Regex.match?(~r/^[^:]+::(?:\*|[^:]+)$/, scope)

  defp normalize_key(key) when key in @keys, do: {:ok, key}
  defp normalize_key("mcp"), do: {:ok, :mcp}
  defp normalize_key("v1"), do: {:ok, :v1}
  defp normalize_key(_value), do: :error

  defp insecure_local_origin_allowed? do
    Application.get_env(:backplane_auth, :allow_insecure_resource_origins, false) and
      Application.get_env(:backplane, :env) in [:dev, :test]
  end
end
