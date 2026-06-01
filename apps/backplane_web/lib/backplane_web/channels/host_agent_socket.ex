defmodule BackplaneWeb.HostAgentSocket do
  use Phoenix.Socket

  alias Backplane.Skills.AgentManage

  channel("host_agent:*", BackplaneWeb.HostAgentChannel)

  @impl true
  def connect(params, socket, connect_info) do
    authenticate_socket(params, socket, connect_info)
  catch
    :exit, _reason -> :error
  end

  defp authenticate_socket(params, socket, connect_info) do
    with host_id when is_binary(host_id) <- host_id(params, connect_info),
         token when is_binary(token) <- host_token(connect_info),
         {:ok, host, auth_token} <- AgentManage.authenticate(host_id, token) do
      metadata = connection_metadata(connect_info)

      {:ok,
       socket
       |> assign(:host, host)
       |> assign(:auth_token, auth_token)
       |> assign(:connection_metadata, metadata)}
    else
      _ -> :error
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

  defp host_id(params, connect_info) do
    params["host_id"] || params["agent_id"] || host_id_header(connect_info)
  end

  defp host_id_header(%{x_headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"x-backplane-host-id", host_id} -> host_id
      {"X-Backplane-Host-Id", host_id} -> host_id
      _other -> nil
    end)
  end

  defp host_id_header(_connect_info), do: nil

  defp connection_metadata(connect_info) do
    {connect_ip, source} =
      x_real_ip(connect_info) ||
        x_forwarded_for(connect_info) ||
        peer_ip(connect_info) ||
        {nil, nil}

    %{connect_ip: connect_ip, connect_ip_source: source}
  end

  defp x_real_ip(%{x_headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"x-real-ip", ip} -> clean_ip(ip, "x-real-ip")
      {"X-Real-IP", ip} -> clean_ip(ip, "x-real-ip")
      _other -> nil
    end)
  end

  defp x_real_ip(_connect_info), do: nil

  defp x_forwarded_for(%{x_headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"x-forwarded-for", value} -> forwarded_ip(value)
      {"X-Forwarded-For", value} -> forwarded_ip(value)
      _other -> nil
    end)
  end

  defp x_forwarded_for(_connect_info), do: nil

  defp forwarded_ip(value) when is_binary(value) do
    value
    |> String.split(",", parts: 2)
    |> List.first()
    |> clean_ip("x-forwarded-for")
  end

  defp forwarded_ip(_value), do: nil

  defp peer_ip(%{peer_data: %{address: address}}) do
    address
    |> :inet.ntoa()
    |> to_string()
    |> clean_ip("peer")
  rescue
    _ -> nil
  end

  defp peer_ip(_connect_info), do: nil

  defp clean_ip(value, source) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      ip -> {ip, source}
    end
  end

  defp clean_ip(_value, _source), do: nil
end
