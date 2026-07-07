defmodule Backplane.HostAgent.Services.Plugins do
  @moduledoc """
  Local MCP service for installing host-agent packaged plugins.
  """

  @behaviour Backplane.HostAgent.LocalService

  alias Backplane.HostAgent.PluginInstaller

  @impl true
  def prefix, do: "host_agent"

  @impl true
  def tools do
    [
      %{
        "name" => "host_agent::list_plugins",
        "description" => "List host-agent packaged plugins and install status"
      },
      %{
        "name" => "host_agent::plugin_status",
        "description" => "Show install status for a host-agent packaged plugin",
        "inputSchema" => plugin_runtime_schema()
      },
      %{
        "name" => "host_agent::install_plugin",
        "description" => "Install or update a host-agent packaged plugin",
        "inputSchema" =>
          Map.merge(plugin_runtime_schema(), %{
            "properties" =>
              Map.merge(plugin_runtime_schema()["properties"], %{
                "target_path" => %{
                  "type" => "string",
                  "description" =>
                    "Optional explicit plugin install directory under the user's home directory"
                },
                "force" => %{
                  "type" => "boolean",
                  "description" => "Replace an existing install. Defaults to true."
                }
              })
          })
      },
      %{
        "name" => "host_agent::remove_plugin",
        "description" => "Remove a host-agent packaged plugin install",
        "inputSchema" =>
          Map.merge(plugin_runtime_schema(), %{
            "properties" =>
              Map.merge(plugin_runtime_schema()["properties"], %{
                "target_path" => %{
                  "type" => "string",
                  "description" =>
                    "Optional explicit plugin install directory under the user's home directory"
                }
              })
          })
      }
    ]
  end

  @impl true
  def call("list_plugins", args, _ctx) when is_map(args) do
    {:ok, %{"plugins" => PluginInstaller.list(args)}}
  end

  def call("plugin_status", %{"plugin" => plugin, "runtime" => runtime} = args, _ctx) do
    PluginInstaller.status(plugin, runtime, args)
  end

  def call("install_plugin", %{"plugin" => plugin, "runtime" => runtime} = args, _ctx) do
    PluginInstaller.install(plugin, runtime, args)
  end

  def call("remove_plugin", %{"plugin" => plugin, "runtime" => runtime} = args, _ctx) do
    PluginInstaller.remove(plugin, runtime, args)
  end

  def call(method, _args, _ctx) when method in ~w(plugin_status install_plugin remove_plugin),
    do: {:error, {:invalid_args, "plugin and runtime are required"}}

  def call(method, _args, _ctx), do: {:error, {:unknown_method, method}}

  defp plugin_runtime_schema do
    %{
      "type" => "object",
      "required" => ["plugin", "runtime"],
      "properties" => %{
        "plugin" => %{
          "type" => "string",
          "enum" => PluginInstaller.plugins(),
          "description" => "Packaged plugin id"
        },
        "runtime" => %{
          "type" => "string",
          "description" => "Target runtime for the selected plugin"
        }
      }
    }
  end
end
