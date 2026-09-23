defmodule Backplane.AiProtocol.Affinity do
  @moduledoc """
  Explicit public affinity for provider-bound state.

  This struct deliberately contains no credential identifier. Public credential scope and
  version labels may bind opaque state to a host-selected credential generation, while the
  credential binding itself remains in `Backplane.AiProtocol.ExecutionContext`.
  """

  @enforce_keys [:profile]
  defstruct [
    :profile,
    :protocol,
    :endpoint,
    :account,
    :workspace,
    :model,
    :credential_scope,
    :credential_version
  ]

  @type field :: String.t() | nil

  @type t :: %__MODULE__{
          profile: String.t(),
          protocol: field(),
          endpoint: field(),
          account: field(),
          workspace: field(),
          model: field(),
          credential_scope: field(),
          credential_version: field()
        }

  @keys [
    :profile,
    :protocol,
    :endpoint,
    :account,
    :workspace,
    :model,
    :credential_scope,
    :credential_version
  ]

  @doc """
  Builds a public affinity. Any credential-like field is rejected to prevent accidental
  exposure through public provider-state envelopes.
  """
  @spec new(map()) :: {:ok, t()} | {:error, Backplane.AiProtocol.Error.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, profile} <- required_string(attrs, :profile),
         :ok <- optional_strings(attrs, @keys -- [:profile]) do
      {:ok,
       %__MODULE__{
         profile: profile,
         protocol: attrs[:protocol],
         endpoint: attrs[:endpoint],
         account: attrs[:account],
         workspace: attrs[:workspace],
         model: attrs[:model],
         credential_scope: attrs[:credential_scope],
         credential_version: attrs[:credential_version]
       }}
    end
  end

  @doc false
  def keys, do: @keys

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> Backplane.AiProtocol.Error.invalid("Affinity profile must be a non-empty string")
    end
  end

  defp optional_strings(attrs, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Map.get(attrs, key) do
        nil ->
          {:cont, :ok}

        value when is_binary(value) and byte_size(value) > 0 ->
          {:cont, :ok}

        _ ->
          {:halt,
           Backplane.AiProtocol.Error.invalid("Affinity #{key} must be a non-empty string")}
      end
    end)
  end
end
