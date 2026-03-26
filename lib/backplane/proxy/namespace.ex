defmodule Backplane.Proxy.Namespace do
  @moduledoc """
  Tool name prefixing and stripping for upstream MCP servers.
  Uses `::` as the namespace separator.
  """

  @separator "::"

  @doc "Prefix a tool name with a namespace."
  @spec prefix(String.t(), String.t()) :: String.t()
  def prefix(namespace, tool_name) do
    namespace <> @separator <> tool_name
  end

  @doc "Strip a namespace prefix from a tool name, returning the original name."
  @spec strip(String.t(), String.t()) :: String.t()
  def strip(namespace, namespaced_name) do
    prefix = namespace <> @separator

    if String.starts_with?(namespaced_name, prefix) do
      String.replace_prefix(namespaced_name, prefix, "")
    else
      namespaced_name
    end
  end

  @doc "Extract the namespace from a namespaced tool name."
  @spec extract_namespace(String.t()) :: {:ok, String.t()} | :error
  def extract_namespace(namespaced_name) do
    case String.split(namespaced_name, @separator, parts: 2) do
      [namespace, _tool] -> {:ok, namespace}
      _ -> :error
    end
  end

  @doc "Returns the separator string."
  @spec separator() :: String.t()
  def separator, do: @separator
end
