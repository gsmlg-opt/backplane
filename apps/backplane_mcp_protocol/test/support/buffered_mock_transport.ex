defmodule BufferedMockTransport do
  @moduledoc """
  A mock transport that delegates parse/encode to STDIO (for buffering)
  but stubs the GenServer behaviour. Used to test chunked STDIO responses.
  """
  @behaviour Backplane.McpProtocol.Transport
  @behaviour Backplane.McpProtocol.Transport.Behaviour

  alias Backplane.McpProtocol.Transport.STDIO

  @impl true
  defdelegate transport_init(opts \\ []), to: STDIO
  @impl true
  defdelegate parse(raw, state), to: STDIO
  @impl true
  defdelegate encode(message, state), to: STDIO
  @impl true
  defdelegate extract_metadata(raw, state), to: STDIO

  @impl Backplane.McpProtocol.Transport.Behaviour
  def start_link(_opts), do: {:ok, self()}

  @impl Backplane.McpProtocol.Transport.Behaviour
  def send_message(_, message, _opts \\ [timeout: 1_000]) do
    if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
      send(pid, {:mcp_send, message})
    end

    :ok
  end

  @impl Backplane.McpProtocol.Transport.Behaviour
  def shutdown(_), do: :ok

  @impl Backplane.McpProtocol.Transport.Behaviour
  def supported_protocol_versions, do: :all
end
