defmodule Backplane.McpProtocol.Transport.Behaviour do
  @moduledoc """
  Defines the behavior that all transport implementations must follow.
  """

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Transport.RequestContext

  @type t :: GenServer.server()
  @typedoc "The JSON-RPC message encoded"
  @type message :: String.t()
  @type reason :: term() | Error.t()

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback send_message(t(), message(), list(opt)) :: :ok | {:error, reason()}
            when opt: {:timeout, pos_integer()} | {:request_context, RequestContext.t()}
  @callback open_stream(t(), message(), list(stream_opt)) ::
              {:ok, term()} | {:error, reason()}
            when stream_opt:
                   {:timeout, pos_integer()}
                   | {:request_context, RequestContext.t()}
                   | {:owner, pid()}
                   | {:subscription_id, String.t() | integer()}
  @callback close_stream(t(), term(), keyword()) :: :ok | {:error, reason()}
  @callback shutdown(t()) :: :ok | {:error, reason()}

  @doc """
  Returns the list of MCP protocol versions supported by this transport.

  ## Examples

      iex> MyTransport.supported_protocol_versions()
      ["2024-11-05", "2025-03-26"]
  """
  @callback supported_protocol_versions() :: [String.t()] | :all

  @optional_callbacks open_stream: 3, close_stream: 3
end
