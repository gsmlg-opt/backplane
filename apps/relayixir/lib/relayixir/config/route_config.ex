defmodule Relayixir.Config.RouteConfig do
  @moduledoc """
  Agent-based route configuration store.
  """

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc """
  Returns all configured routes.
  """
  @spec get_routes() :: [map()]
  def get_routes do
    Agent.get(__MODULE__, & &1)
  end

  @doc """
  Replaces all routes with the given list.
  """
  @spec put_routes([map()]) :: :ok
  def put_routes(routes) when is_list(routes) do
    Agent.update(__MODULE__, fn _ -> routes end)
  end

  @doc """
  Finds the first matching route for the given host and path.

  Routes are matched by `host_match` (exact or wildcard "*") and `path_prefix`.
  """
  @spec find_route(String.t(), String.t()) :: map() | nil
  def find_route(host, path) do
    routes = get_routes()

    Enum.find(routes, fn route ->
      host_matches?(route, host) && path_matches?(route, path)
    end)
  end

  defp host_matches?(%{host_match: "*"}, _host), do: true
  defp host_matches?(%{host_match: match}, host), do: match == host
  defp host_matches?(_route, _host), do: true

  defp path_matches?(%{path_prefix: prefix}, path) when is_binary(prefix) do
    String.starts_with?(path, prefix)
  end

  defp path_matches?(_route, _path), do: true
end
