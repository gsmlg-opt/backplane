defmodule Backplane.Auth.Resources do
  @moduledoc """
  Defines canonical OAuth protected resources and their resource-relative scopes.
  """

  alias Backplane.Endpoints
  alias Backplane.WebOrigins

  @type base :: :mcp | :skill_protocol | :v1
  @type key :: base() | {:endpoint, String.t(), :mcp | :v1}

  @keys [:mcp, :skill_protocol, :v1]
  @identity_scopes ["openid", "profile", "email"]
  @local_http_hosts ["localhost", "127.0.0.1", "::1"]
  @operation_scope_pattern ~r/\A(?:\*|[\w-]+::(?:\*|[\w-]+))\z/
  @v1_scopes ["llm::models", "llm::invoke", "llm::manage", "llm::*", "*"]
  @skill_protocol_scopes ["skill::read", "skill::*", "*"]
  @persisted_endpoint ~r/\Aendpoint:([a-z0-9][a-z0-9-]{0,62}):(mcp|v1)\z/
  @endpoint_feature %{mcp: :mcp, v1: :llm}

  @spec keys() :: [key()]
  def keys, do: @keys

  @spec endpoint_key(String.t(), :mcp | :v1) :: key()
  def endpoint_key(name, base) when is_binary(name) and base in [:mcp, :v1],
    do: {:endpoint, name, base}

  @spec base(key()) :: base()
  def base({:endpoint, _name, base}), do: base
  def base(key) when key in @keys, do: key

  @spec endpoint?(term()) :: boolean()
  def endpoint?({:endpoint, name, base}) when is_binary(name) and base in [:mcp, :v1], do: true
  def endpoint?(_key), do: false

  @spec oauth_bindable?(term()) :: boolean()
  def oauth_bindable?(key) when key in [:mcp, :v1], do: true
  def oauth_bindable?(key), do: endpoint?(key)

  @spec to_persisted(key()) :: String.t()
  def to_persisted({:endpoint, name, base}), do: "endpoint:#{name}:#{base}"
  def to_persisted(key) when key in @keys, do: Atom.to_string(key)

  @spec from_persisted(String.t()) :: {:ok, key()} | :error
  def from_persisted("mcp"), do: {:ok, :mcp}
  def from_persisted("skill_protocol"), do: {:ok, :skill_protocol}
  def from_persisted("v1"), do: {:ok, :v1}

  def from_persisted(value) when is_binary(value) do
    case Regex.run(@persisted_endpoint, value) do
      [_all, name, base] -> {:ok, {:endpoint, name, String.to_existing_atom(base)}}
      nil -> :error
    end
  end

  def from_persisted(_value), do: :error

  @spec path(key()) :: String.t()
  def path({:endpoint, name, base}), do: "/endpoints/#{name}/#{base}"
  def path(:mcp), do: "/mcp"
  def path(:skill_protocol), do: "/skill-protocol/v1"
  def path(:v1), do: "/v1"

  @spec uri(key()) :: String.t()
  def uri(key), do: WebOrigins.api_url(path(key))

  @spec metadata_uri(key()) :: String.t()
  def metadata_uri({:endpoint, _name, _base} = key),
    do: WebOrigins.api_url("/.well-known/oauth-protected-resource#{path(key)}")

  def metadata_uri(key),
    do: WebOrigins.api_url("/.well-known/oauth-protected-resource/#{key}")

  @spec documentation_uri(key()) :: String.t()
  def documentation_uri({:endpoint, _name, base}), do: documentation_uri(base)
  def documentation_uri(:mcp), do: WebOrigins.api_url("/docs/mcp")
  def documentation_uri(:skill_protocol), do: WebOrigins.api_url("/docs/skills")
  def documentation_uri(:v1), do: WebOrigins.api_url("/docs/llm")

  @spec from_uri(String.t()) :: {:ok, key()} | :error
  def from_uri(value) when is_binary(value) do
    Enum.find_value(@keys, endpoint_from_uri(value), fn key ->
      if value == uri(key), do: {:ok, key}
    end)
  end

  defp endpoint_from_uri(value) do
    prefix = WebOrigins.api_url("/endpoints/")

    with true <- String.starts_with?(value, prefix),
         [name, base] <- value |> String.replace_prefix(prefix, "") |> String.split("/"),
         {:ok, {:endpoint, ^name, base} = key} <- from_persisted("endpoint:#{name}:#{base}"),
         {:ok, _endpoint} <- Endpoints.active(name, Map.fetch!(@endpoint_feature, base)) do
      {:ok, key}
    else
      _no_match -> :error
    end
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
  def valid_scope?({:endpoint, _name, base}, scope), do: valid_scope?(base, scope)
  def valid_scope?(:mcp, scope), do: mcp_operation_scope?(scope)
  def valid_scope?(:skill_protocol, scope), do: scope in @skill_protocol_scopes
  def valid_scope?(:v1, scope), do: scope in @v1_scopes

  @spec operation_scope?(key(), String.t()) :: boolean()
  def operation_scope?({:endpoint, _name, base}, scope), do: operation_scope?(base, scope)
  def operation_scope?(:mcp, scope), do: mcp_operation_scope?(scope)
  def operation_scope?(:skill_protocol, scope), do: scope in @skill_protocol_scopes
  def operation_scope?(:v1, scope), do: scope in @v1_scopes

  @spec protected_operation_scope?(String.t()) :: boolean()
  def protected_operation_scope?("system::" <> _rest), do: false
  def protected_operation_scope?(scope), do: operation_scope_name?(scope)

  @spec default_scopes(key(), [String.t()], [String.t()]) ::
          {:ok, [String.t()]} | {:error, :invalid_scope}
  def default_scopes(key, client_scopes, user_scopes) do
    user_set = MapSet.new(user_scopes)

    scopes =
      client_scopes
      |> Enum.filter(&(MapSet.member?(user_set, &1) and operation_scope?(key, &1)))
      |> Enum.reject(&(&1 in @identity_scopes))
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
  defp normalize_key("skill_protocol"), do: {:ok, :skill_protocol}
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
      String.downcase(host) in @local_http_hosts
  end
end
