defmodule Backplane.HostAgent.Services do
  @moduledoc """
  Registry for stateless host-agent local MCP services.
  """

  @default_services [
    Backplane.HostAgent.Services.Memory,
    Backplane.HostAgent.Services.Plugins,
    Backplane.HostAgent.Services.Day,
    Backplane.HostAgent.Services.Math
  ]

  def services do
    Application.get_env(:backplane_host_agent, :local_services, @default_services)
  end

  def list_tools do
    Enum.flat_map(services(), & &1.tools())
  end

  def resolve(name) when is_binary(name) do
    case String.split(name, "::", parts: 2) do
      [prefix, bare] ->
        find_service(prefix, bare)

      _ ->
        :error
    end
  end

  def resolve(_name), do: :error

  defp find_service(prefix, bare) do
    case Enum.find(services(), &(&1.prefix() == prefix)) do
      nil -> :error
      service -> {:ok, service, bare}
    end
  end
end
