defmodule Backplane.McpProtocol.Transport.RequestContext do
  @moduledoc """
  Immutable protocol context captured for one outbound transport send.

  The context belongs to the request, not the connection. This lets one HTTP
  transport carry a modern discovery probe followed by a legacy initialize
  request without retaining a transport-global protocol era.
  """

  alias Backplane.McpProtocol.Client.State
  alias Backplane.McpProtocol.Protocol.Profile
  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Transport.StreamableHTTP.Headers

  @enforce_keys [:profile, :era, :lifecycle, :protocol_version, :method, :params]
  defstruct [
    :profile,
    :era,
    :lifecycle,
    :protocol_version,
    :method,
    params: %{},
    parameter_headers: %{}
  ]

  @type t :: %__MODULE__{
          profile: Profile.t(),
          era: Profile.era(),
          lifecycle: Profile.lifecycle(),
          protocol_version: String.t(),
          method: String.t(),
          params: map(),
          parameter_headers: map()
        }

  @spec new(String.t(), map(), State.t() | map(), keyword()) :: t()
  def new(method, params, state, opts \\ [])
      when is_binary(method) and is_map(params) and is_map(state) and is_list(opts) do
    version = Map.get(state, :protocol_version)
    {:ok, profile} = Registry.profile(version)
    era = request_era(method, Map.get(state, :era), profile.era)
    lifecycle = if era == :modern, do: :per_request, else: :initialize

    %__MODULE__{
      profile: profile,
      era: era,
      lifecycle: lifecycle,
      protocol_version: version,
      method: method,
      params: params,
      parameter_headers: Keyword.get(opts, :parameter_headers, %{})
    }
  end

  @doc "Returns true when this individual request uses the stateless modern protocol."
  @spec modern?(t()) :: boolean()
  def modern?(%__MODULE__{era: :modern}), do: true
  def modern?(%__MODULE__{}), do: false

  @doc "Normalizes and encodes the request's declared `Mcp-Param-*` mirrors."
  @spec parameter_headers(t() | map()) :: {:ok, map()} | {:error, term()}
  def parameter_headers(%__MODULE__{parameter_headers: headers}), do: Headers.parameter_headers(headers)

  def parameter_headers(headers) when is_map(headers), do: Headers.parameter_headers(headers)

  @doc "Encodes one primitive request parameter for safe HTTP header transport."
  @spec mirrored_value(term()) :: {:ok, String.t()} | :omit | {:error, atom()}
  defdelegate mirrored_value(value), to: Headers, as: :encode_mirrored

  defp request_era("server/discover", _state_era, _profile_era), do: :modern
  defp request_era("initialize", _state_era, _profile_era), do: :legacy
  defp request_era(_method, era, _profile_era) when era in [:modern, :legacy], do: era
  defp request_era(_method, _era, profile_era), do: profile_era
end
