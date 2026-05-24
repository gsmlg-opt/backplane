defmodule Backplane.HostAgent.HttpServer do
  @moduledoc """
  Bandit HTTP server hosting `Backplane.HostAgent.MemoryRouter`.

  Returns a child spec when the config supplies a positive `http_port`,
  otherwise returns `nil` so the caller can skip starting an HTTP server.
  """

  alias Backplane.HostAgent.MemoryRouter

  @doc """
  Build a Bandit child spec for the supplied config.

  Returns `nil` if `http_port` is not set, so callers can use the result
  directly in `Enum.reject(&is_nil/1)` style child lists.
  """
  @spec child_spec(map() | struct()) :: Supervisor.child_spec() | nil
  def child_spec(%{http_port: nil}), do: nil
  def child_spec(%{http_port: 0}), do: nil

  def child_spec(%{http_port: port, http_bind: bind}) when is_integer(port) do
    {:ok, ip} = parse_bind(bind)

    {Bandit,
     plug: MemoryRouter,
     scheme: :http,
     ip: ip,
     port: port,
     thousand_island_options: [transport_options: [reuseaddr: true]]}
  end

  def child_spec(_), do: nil

  defp parse_bind(nil), do: {:ok, {127, 0, 0, 1}}
  defp parse_bind(""), do: {:ok, {127, 0, 0, 1}}

  defp parse_bind(addr) when is_binary(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:ok, {127, 0, 0, 1}}
    end
  end
end
