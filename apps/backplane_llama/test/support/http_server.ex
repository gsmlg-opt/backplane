defmodule BackplaneLlama.Test.HTTPServer do
  @moduledoc false

  import ExUnit.Assertions

  def open(method, path, callback) do
    {:ok, supervisor} = Supervisor.start_link([{Agent, fn -> [] end}], strategy: :one_for_one)
    Process.unlink(supervisor)
    [{Agent, state, _, _}] = Supervisor.which_children(supervisor)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        :ok = Supervisor.terminate_child(supervisor, :http)
        results = Agent.get(state, & &1)

        for {kind, reason, stacktrace} <- results do
          :erlang.raise(kind, reason, stacktrace)
        end

        assert results == [:ok],
               "Expected exactly one successful HTTP request, received: #{inspect(results)}"
      after
        Supervisor.stop(supervisor)
      end
    end)

    listener =
      {Bandit,
       plug: {__MODULE__, {state, method, path, callback}},
       ip: {127, 0, 0, 1},
       port: 0,
       startup_log: false,
       thousand_island_options: [shutdown_timeout: 0]}

    {:ok, listener} =
      Supervisor.start_child(supervisor, Supervisor.child_spec(listener, id: :http))

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    %{port: port}
  end

  def init(options), do: options

  def call(conn, {state, method, path, callback}) do
    try do
      assert conn.method == method
      assert conn.request_path == path
      conn = callback.(conn)
      Agent.update(state, &[:ok | &1])
      conn
    catch
      kind, reason ->
        failure = {kind, reason, __STACKTRACE__}
        Agent.update(state, &[failure | &1])
        Plug.Conn.send_resp(conn, 500, "HTTP fixture callback failed")
    end
  end
end
