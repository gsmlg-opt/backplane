defmodule Backplane.MCP.Info do
  @moduledoc """
  Identity and protocol version metadata reported by the MCP transport
  and upstream client.

  Supports all four MCP specification versions:
  - `2024-11-05` — Initial: JSON-RPC 2.0, stdio/HTTP+SSE, Tools/Resources/Prompts, Sampling
  - `2025-03-26` — Streamable HTTP, tool annotations, completions, audio content
  - `2025-06-18` — Structured tool output (outputSchema), elicitation, removed batching
  - `2025-11-25` — OIDC, icon metadata, experimental tasks, extensions framework
  """

  alias Backplane.McpProtocol

  # Ordered list for comparison — index 0 is oldest
  @version_order %{
    "2024-11-05" => 0,
    "2025-03-26" => 1,
    "2025-06-18" => 2,
    "2025-11-25" => 3
  }

  @doc "Current Backplane release version (from the :backplane app spec)."
  @spec version() :: String.t()
  def version do
    case Application.spec(:backplane, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  @doc "Latest MCP protocol version supported by this server."
  @spec protocol_version() :: String.t()
  def protocol_version, do: McpProtocol.protocol_version()

  @doc "All MCP protocol versions supported by this server."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: McpProtocol.supported_protocol_versions()

  @doc """
  Negotiate protocol version with client.

  If the client requests a supported version, that version is returned.
  If the client requests an unsupported version or none at all, the
  latest supported version is returned.
  """
  @spec negotiate_version(String.t() | nil) :: String.t()
  def negotiate_version(version), do: McpProtocol.negotiate_version(version)

  @doc """
  Return an integer ordinal for a version string, for comparison.

  Higher ordinal = newer version. Returns 0 for unknown versions.

  ## Examples

      iex> Backplane.MCP.Info.version_ordinal("2024-11-05")
      0
      iex> Backplane.MCP.Info.version_ordinal("2025-11-25")
      3
  """
  @spec version_ordinal(String.t()) :: non_neg_integer()
  def version_ordinal(version), do: Map.get(@version_order, version, 0)

  @doc """
  Check if version `a` is greater than or equal to version `b`.
  """
  @spec version_gte?(String.t(), String.t()) :: boolean()
  def version_gte?(a, b), do: version_ordinal(a) >= version_ordinal(b)

  @doc """
  Return the server capabilities map appropriate for the given negotiated version.

  Older versions receive fewer capabilities to avoid confusing older clients.
  """
  @spec capabilities_for_version(String.t()) :: map()
  def capabilities_for_version("2024-11-05") do
    %{
      tools: %{listChanged: true},
      resources: %{listChanged: true},
      prompts: %{listChanged: true},
      logging: %{}
    }
  end

  def capabilities_for_version("2025-03-26") do
    %{
      tools: %{listChanged: true},
      resources: %{listChanged: true},
      prompts: %{listChanged: true},
      completions: %{},
      logging: %{}
    }
  end

  def capabilities_for_version("2025-06-18") do
    %{
      tools: %{listChanged: true},
      resources: %{listChanged: true},
      prompts: %{listChanged: true},
      completions: %{},
      logging: %{}
    }
  end

  def capabilities_for_version("2025-11-25") do
    %{
      tools: %{listChanged: true},
      resources: %{listChanged: true},
      prompts: %{listChanged: true},
      completions: %{},
      logging: %{},
      experimental: %{tasks: %{}}
    }
  end

  # Fallback for unknown versions — use latest capabilities
  def capabilities_for_version(_), do: capabilities_for_version(protocol_version())
end
