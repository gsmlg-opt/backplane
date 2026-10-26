defmodule Backplane.HostAgent.Memory.Reducer do
  @moduledoc """
  Shared argument, scope and JSON helpers for host Memory commands and slots.
  Content hashing remains available for retained historical fixture data.
  """

  @default_scope "proj_local"

  @doc "Returns the lowercase SHA-256 hex digest for memory content."
  def content_hash(content) when is_binary(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end

  @doc "Resolves write scope from memory config and rejects caller drift."
  def resolve_scope(args, config) when is_map(args) and is_map(config) do
    bound_scope = config_value(config, :bound_scope) || @default_scope

    case optional_trimmed(args, "scope") do
      nil -> {:ok, bound_scope}
      ^bound_scope -> {:ok, bound_scope}
      _other -> {:error, :invalid_scope}
    end
  end

  @doc "Validates a required, non-empty string argument."
  def required_string(args, key) when is_map(args) do
    case optional_trimmed(args, key) do
      nil -> {:error, {:invalid_args, "#{key} is required"}}
      value -> {:ok, value}
    end
  end

  @doc "Returns a trimmed optional string argument."
  def optional_string(args, key) when is_map(args), do: optional_trimmed(args, key)

  def value(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  end

  def encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, {:invalid_args, "value must be JSON encodable"}}
    end
  end

  def decode_json(nil, default), do: default

  def decode_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  def decode_json(_json, default), do: default

  defp optional_trimmed(args, key) do
    case value(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp config_value(config, key), do: Map.get(config, key, Map.get(config, Atom.to_string(key)))
end
