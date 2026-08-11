{:ok, _applications} = Application.ensure_all_started(:backplane_mcp_protocol)

Code.require_file("conformance_client.ex", __DIR__)

scenario = System.fetch_env!("MCP_CONFORMANCE_SCENARIO")
protocol_version = System.fetch_env!("MCP_CONFORMANCE_PROTOCOL_VERSION")

context =
  case System.get_env("MCP_CONFORMANCE_CONTEXT") do
    nil -> %{}
    encoded -> JSON.decode!(encoded)
  end

case List.last(System.argv()) do
  nil ->
    IO.puts(:stderr, "conformance client requires the scenario URL as its final argument")
    System.halt(2)

  url ->
    case Conformance.Client.run(url, scenario, context, protocol_version) do
      :ok ->
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "conformance client failed: #{inspect(reason, limit: 20, printable_limit: 500)}")
        System.halt(1)
    end
end
