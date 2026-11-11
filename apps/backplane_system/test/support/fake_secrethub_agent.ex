defmodule Backplane.SecretHub.FakeAgent do
  @moduledoc """
  In-memory stand-in for a SecretHub Agent socket in tests.

  Speaks the Agent's JSON-lines protocol for `secret_put`, `secret_delete` and
  `get_secret`, keeps versions, reports identical republication as
  `unchanged`, and notifies `owner` of every request. `set_available/2`
  closes the listener so clients see an unavailable Agent.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def secrets(pid), do: GenServer.call(pid, :secrets)
  def set_available(pid, available?), do: GenServer.call(pid, {:available, available?})

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    state = %{path: path, owner: Keyword.fetch!(opts, :owner), listener: nil, secrets: %{}}
    {:ok, listen(state)}
  end

  @impl true
  def handle_call(:secrets, _from, state), do: {:reply, state.secrets, state}

  def handle_call({:available, true}, _from, %{listener: nil} = state),
    do: {:reply, :ok, listen(state)}

  def handle_call({:available, false}, _from, %{listener: listener} = state)
      when listener != nil do
    :gen_tcp.close(listener)
    File.rm(state.path)
    {:reply, :ok, %{state | listener: nil}}
  end

  def handle_call({:available, _}, _from, state), do: {:reply, :ok, state}

  def handle_call({:request, action, params}, _from, state) do
    send(state.owner, {:secrethub_request, action, params})
    {reply, secrets} = respond(action, params, state.secrets)
    {:reply, reply, %{state | secrets: secrets}}
  end

  @impl true
  def handle_info({:accepted, listener}, %{listener: listener} = state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: File.rm(state.path)

  defp listen(state) do
    File.rm(state.path)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        ifaddr: {:local, to_charlist(state.path)}
      ])

    server = self()
    spawn_link(fn -> accept_loop(listener, server) end)
    %{state | listener: listener}
  end

  defp accept_loop(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve(socket, server)
        accept_loop(listener, server)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, server) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000),
         {:ok, %{"request_id" => id, "action" => action, "params" => params}} <-
           Jason.decode(line) do
      frame =
        case GenServer.call(server, {:request, action, params}) do
          {:ok, data} -> %{request_id: id, status: "ok", data: data}
          {:error, code} -> %{request_id: id, status: "error", error: %{code: code}}
        end

      :gen_tcp.send(socket, Jason.encode!(frame) <> "\n")
    end

    :gen_tcp.close(socket)
  end

  defp respond("secret_put", %{"path" => path, "data" => data}, secrets) do
    case secrets[path] do
      %{data: ^data, version: version} ->
        {{:ok, %{"status" => "unchanged", "path" => path, "version" => version}}, secrets}

      %{version: version} ->
        {{:ok, %{"status" => "updated", "path" => path, "version" => version + 1}},
         Map.put(secrets, path, %{data: data, version: version + 1})}

      nil ->
        {{:ok, %{"status" => "created", "path" => path, "version" => 1}},
         Map.put(secrets, path, %{data: data, version: 1})}
    end
  end

  defp respond("secret_delete", %{"path" => path}, secrets) do
    if Map.has_key?(secrets, path),
      do: {{:ok, %{"status" => "deleted", "path" => path}}, Map.delete(secrets, path)},
      else: {{:ok, %{"status" => "absent"}}, secrets}
  end

  defp respond(_action, _params, secrets), do: {{:error, "INVALID_REQUEST"}, secrets}
end
