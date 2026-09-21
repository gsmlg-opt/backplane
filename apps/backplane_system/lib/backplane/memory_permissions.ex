defmodule Backplane.MemoryPermissions do
  @moduledoc "Canonical permission classes for Backplane Memory surfaces."

  @spec tool_permissions() :: %{String.t() => String.t()}
  def tool_permissions, do: Backplane.MemoryToolContract.permissions()

  @spec for_tool(String.t()) :: {:ok, String.t()} | :error
  def for_tool(name) when is_binary(name), do: Backplane.MemoryToolContract.permission(name)

  @spec for_tool!(String.t()) :: String.t()
  def for_tool!(name) when is_binary(name), do: Backplane.MemoryToolContract.permission!(name)
end
