defmodule BackplaneWeb.HostAgentSocket do
  use Phoenix.Socket

  alias Backplane.Skills.Hosts

  channel("host_agent:*", BackplaneWeb.HostAgentChannel)

  @impl true
  def connect(_params, socket, connect_info) do
    connect_info
    |> host_token()
    |> Hosts.verify_token()
    |> case do
      {:ok, host, auth_token} ->
        {:ok, socket |> assign(:host, host) |> assign(:auth_token, auth_token)}

      :error ->
        :error
    end
  end

  @impl true
  def id(socket), do: "host_agent:#{socket.assigns.host.id}"

  defp host_token(%{x_headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"x-backplane-host-token", token} -> token
      {"X-Backplane-Host-Token", token} -> token
      _other -> nil
    end)
  end

  defp host_token(_connect_info), do: nil
end
