defmodule Backplane.McpProtocol.Test.HTTPServer do
  @moduledoc false

  import ExUnit.Assertions

  def open do
    {:ok, supervisor} =
      Supervisor.start_link([{Agent, fn -> %{routes: %{}, errors: []} end}],
        strategy: :one_for_one
      )

    Process.unlink(supervisor)
    [{Agent, state, _, _}] = Supervisor.which_children(supervisor)
    server = %{supervisor: supervisor, state: state}

    ExUnit.Callbacks.on_exit(fn ->
      try do
        down(server)
        verify!(server)
      after
        Supervisor.stop(supervisor)
      end
    end)

    {:ok, listener} =
      Supervisor.start_child(
        supervisor,
        Supervisor.child_spec(
          {Bandit,
           plug: {__MODULE__, state},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [shutdown_timeout: 0]},
          id: :http,
          restart: :temporary
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    Map.merge(server, %{listener: listener, port: port})
  end

  def expect(server, callback), do: expect(server, :any, :any, callback)

  def expect(server, method, path, callback),
    do: register(server, method, path, callback, 1, :infinity)

  def expect_once(server, callback), do: expect_once(server, :any, :any, callback)

  def expect_once(server, method, path, callback),
    do: register(server, method, path, callback, 1, 1)

  def stub(server, callback), do: stub(server, :any, :any, callback)

  def stub(server, method, path, callback),
    do: register(server, method, path, callback, 0, :infinity)

  def down(server) do
    case Supervisor.terminate_child(server.supervisor, :http) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  def verify!(server) do
    %{routes: routes, errors: errors} = Agent.get(server.state, & &1)

    case Enum.reverse(errors) do
      [{kind, reason, stacktrace} | _] -> :erlang.raise(kind, reason, stacktrace)
      [] -> :ok
    end

    for {{method, path}, route} <- routes do
      assert route.count >= route.minimum, "Missing HTTP request: #{method} #{path}"

      assert route.maximum == :infinity or route.count <= route.maximum,
             "Too many HTTP requests: #{method} #{path}"
    end

    :ok
  end

  def init(state), do: state

  def call(conn, state) do
    admission =
      Agent.get_and_update(state, fn data ->
        key =
          Enum.find(
            [
              {conn.method, conn.request_path},
              {conn.method, :any},
              {:any, conn.request_path},
              {:any, :any}
            ],
            &Map.has_key?(data.routes, &1)
          )

        case key && Map.fetch!(data.routes, key) do
          nil ->
            error = %ExUnit.AssertionError{
              message: "Unexpected HTTP request: #{conn.method} #{conn.request_path}"
            }

            {{:error, error}, %{data | errors: [{:error, error, []} | data.errors]}}

          route ->
            updated = put_in(data.routes[key].count, route.count + 1)

            if route.maximum != :infinity and route.count >= route.maximum do
              error = %ExUnit.AssertionError{
                message: "Too many HTTP requests: #{conn.method} #{conn.request_path}"
              }

              {{:error, error}, %{updated | errors: [{:error, error, []} | updated.errors]}}
            else
              {{:ok, route.callback}, updated}
            end
        end
      end)

    case admission do
      {:ok, callback} ->
        try do
          callback.(conn)
        catch
          kind, reason ->
            failure = {kind, reason, __STACKTRACE__}
            Agent.update(state, &%{&1 | errors: [failure | &1.errors]})
            Plug.Conn.send_resp(conn, 500, "HTTP fixture callback failed")
        end

      {:error, _error} ->
        Plug.Conn.send_resp(conn, 500, "Unexpected HTTP request")
    end
  end

  defp register(server, method, path, callback, minimum, maximum) do
    Agent.update(server.state, fn data ->
      put_in(data.routes[{method, path}], %{
        callback: callback,
        minimum: minimum,
        maximum: maximum,
        count: 0
      })
    end)
  end
end
