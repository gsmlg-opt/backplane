defmodule Backplane.McpProtocol.Protocol.Profile do
  @moduledoc """
  Describes the lifecycle and wire surface of an MCP protocol version.

  Profiles keep the session-oriented legacy revisions separate from the
  stateless protocol introduced in `2026-07-28`.
  """

  @enforce_keys [:version, :era, :lifecycle, :request_methods, :notification_methods]
  defstruct [
    :version,
    :era,
    :lifecycle,
    request_methods: [],
    notification_methods: [],
    features: [],
    cacheable_methods: [],
    named_methods: [],
    extensions: %{}
  ]

  @type era :: :legacy | :modern
  @type lifecycle :: :initialize | :per_request

  @type t :: %__MODULE__{
          version: String.t(),
          era: era(),
          lifecycle: lifecycle(),
          request_methods: [String.t()],
          notification_methods: [String.t()],
          features: [atom()],
          cacheable_methods: [String.t()],
          named_methods: [String.t()],
          extensions: %{optional(String.t()) => map()}
        }

  @doc false
  @spec legacy(module()) :: t()
  def legacy(module) do
    %__MODULE__{
      version: module.version(),
      era: :legacy,
      lifecycle: :initialize,
      request_methods: module.request_methods(),
      notification_methods: module.notification_methods(),
      features: module.supported_features()
    }
  end
end
