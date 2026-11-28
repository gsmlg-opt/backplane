defmodule Backplane.HostAgent.Services.CDP do
  @moduledoc "Host configuration and entry points for the local Chrome DevTools service."
  @behaviour Backplane.HostAgent.LocalService

  alias Backplane.CDP
  alias Backplane.CDP.MCP
  alias Backplane.HostAgent.Config

  def configure(host_config) do
    Application.put_env(:backplane_cdp, :config, Map.get(host_config, :cdp, %{}))
  end

  # Release commands run in a fresh VM without the host worker.
  def cli(argv) when argv in [[], ["--help"], ["-h"], ["help"]], do: CDP.CLI.main(argv)

  def cli(argv) do
    case Config.load_default() do
      {:ok, config} ->
        configure(config)
        CDP.CLI.main(argv)

      {:error, {:missing, _path}} ->
        if System.get_env("BACKPLANE_HOST_AGENT_CONFIG") in [nil, ""] and
             Application.get_env(:backplane_host_agent, :config_path) in [nil, ""] do
          CDP.CLI.main(argv)
        else
          cli_config_error()
        end

      {:error, _reason} ->
        cli_config_error()
    end
  end

  @spec cli_config_error() :: no_return()
  defp cli_config_error do
    IO.puts(:stderr, "Cannot load host agent configuration at #{Config.resolved_path()}")
    System.halt(1)
  end

  @impl true
  def prefix, do: "cdp"

  @impl true
  def tools do
    if CDP.enabled?(),
      do: Enum.map(MCP.tools(), &Map.update!(&1, "name", fn name -> "cdp::" <> name end)),
      else: []
  end

  @impl true
  def call(method, args, ctx) do
    if CDP.enabled?() and MCP.known?(method) do
      case MCP.aggregate(ctx.agent_id, method, args) do
        {:ok, blocks} -> {:content, blocks}
        {:error, reason} -> {:tool_error, reason}
      end
    else
      {:error, {:unknown_method, method}}
    end
  end
end
