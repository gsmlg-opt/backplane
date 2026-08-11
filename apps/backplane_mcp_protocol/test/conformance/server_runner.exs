Code.require_file("conformance_server.ex", __DIR__)

port =
  case List.last(System.argv()) do
    nil ->
      4105

    value ->
      case Integer.parse(value) do
        {port, ""} when port in 1..65_535 -> port
        _invalid -> raise ArgumentError, "invalid conformance server port: #{inspect(value)}"
      end
  end

case Conformance.Server.start_link(port: port) do
  {:ok, supervisor} ->
    IO.puts("MCP conformance server listening on http://127.0.0.1:#{port}/mcp")
    monitor = Process.monitor(supervisor)

    receive do
      {:DOWN, ^monitor, :process, ^supervisor, reason} ->
        IO.puts(:stderr, "MCP conformance server stopped: #{inspect(reason)}")
        System.halt(1)
    end

  {:error, reason} ->
    IO.puts(:stderr, "MCP conformance server failed to start: #{inspect(reason)}")
    System.halt(1)
end
