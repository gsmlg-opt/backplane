defmodule Backplane.Registry.Namespace do
  @moduledoc """
  Helpers for MCP tool namespace prefixes.

  Prefixes are stored without path separators because tool names are rendered as
  `<prefix>::<tool_name>`.
  """

  @separator "::"
  @prefix_format ~r/^[A-Za-z0-9_-]+$/

  @doc "Returns the namespace separator used in tool names."
  @spec separator() :: String.t()
  def separator, do: @separator

  @doc "Normalize user-provided namespace prefixes."
  @spec normalize_prefix(term()) :: term()
  def normalize_prefix(prefix) when is_binary(prefix) do
    prefix
    |> String.trim()
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
  end

  def normalize_prefix(prefix), do: prefix

  @doc "Checks whether a normalized prefix is valid for MCP tool namespaces."
  @spec valid_prefix?(term()) :: boolean()
  def valid_prefix?(prefix) when is_binary(prefix) do
    prefix != "" and Regex.match?(@prefix_format, prefix)
  end

  def valid_prefix?(_prefix), do: false

  @doc "Prefix a tool name with a normalized namespace."
  @spec prefix(String.t(), String.t()) :: String.t()
  def prefix(namespace, tool_name) do
    normalize_prefix(namespace) <> @separator <> tool_name
  end
end
