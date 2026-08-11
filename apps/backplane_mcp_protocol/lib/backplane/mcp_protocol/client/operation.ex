defmodule Backplane.McpProtocol.Client.Operation do
  @moduledoc """
  Represents an operation to be performed by the MCP client.

  This struct encapsulates all information about a client API call:
  - `method` - The MCP method to call
  - `params` - The parameters to send to the server
  - `progress_opts` - Progress tracking options (optional)
  - `timeout` - The timeout for this specific operation (default: 30 seconds)
  """

  @type progress_options :: [
          token: String.t() | integer(),
          callback: (String.t() | integer(), number(), number() | nil -> any())
        ]

  @type t :: %__MODULE__{
          method: String.t(),
          params: map(),
          extra_meta: map(),
          progress_opts: progress_options() | nil,
          timeout: pos_integer()
        }

  defstruct [
    :method,
    :timeout,
    params: %{},
    extra_meta: %{},
    progress_opts: []
  ]

  @doc """
  Creates a new operation struct.

  ## Parameters

    * `attrs` - Map containing the operation attributes
      * `:method` - The MCP method name (required)
      * `:params` - The parameters to send to the server (required)
      * `:extra_meta` - Caller-supplied request metadata (optional)
      * `:progress_opts` - Progress tracking options (optional)
      * `:timeout` - The timeout for this operation in milliseconds (optional, defaults to 30s)
  """
  @spec new(%{
          required(:method) => String.t(),
          optional(:params) => map(),
          optional(:extra_meta) => map(),
          optional(:progress_opts) => progress_options() | nil,
          optional(:timeout) => pos_integer()
        }) :: t()
  def new(%{method: method, timeout: timeout} = attrs) do
    %__MODULE__{
      method: method,
      params: Map.get(attrs, :params) || %{},
      extra_meta: Map.get(attrs, :extra_meta) || %{},
      progress_opts: Map.get(attrs, :progress_opts),
      timeout: timeout
    }
  end
end
