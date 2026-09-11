defmodule Backplane.AiProtocol.Error do
  @moduledoc """
  Structured, sanitized protocol error.

  `message` is safe for presentation by default. Provider payloads and opaque state are never
  placed here by canonical constructors.
  """

  @enforce_keys [:kind, :stage]
  defstruct [
    :kind,
    :stage,
    :http_status,
    :provider_code,
    :message,
    :retry_hint,
    :retry_after_ms,
    :request_id,
    :attempt_id,
    :upstream_outcome,
    :partial_output,
    :compatibility,
    details: %{}
  ]

  @type kind ::
          :invalid_request
          | :authentication
          | :authorization
          | :not_found
          | :rate_limited
          | :upstream_error
          | :incompatible
          | :timeout
          | :cancelled
          | :internal

  @type upstream_outcome :: :not_submitted | :known | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          stage: atom(),
          http_status: pos_integer() | nil,
          provider_code: String.t() | nil,
          message: String.t() | nil,
          retry_hint: :retryable | :not_retryable | nil,
          retry_after_ms: non_neg_integer() | nil,
          request_id: String.t() | nil,
          attempt_id: String.t() | nil,
          upstream_outcome: upstream_outcome() | nil,
          partial_output: map() | nil,
          compatibility: map() | nil,
          details: map()
        }

  @keys [
    :kind,
    :stage,
    :http_status,
    :provider_code,
    :message,
    :retry_hint,
    :retry_after_ms,
    :request_id,
    :attempt_id,
    :upstream_outcome,
    :partial_output,
    :compatibility,
    :details
  ]

  @spec invalid(String.t()) :: {:error, t()}
  def invalid(message),
    do: {:error, %__MODULE__{kind: :invalid_request, stage: :validation, message: message}}

  @spec invalid!(String.t()) :: t()
  def invalid!(message) do
    {:error, error} = invalid(message)
    error
  end

  @spec incompatible(String.t(), map() | nil) :: {:error, t()}
  def incompatible(message, compatibility \\ nil, stage \\ :translation) do
    {:error,
     %__MODULE__{
       kind: :incompatible,
       stage: stage,
       message: message,
       compatibility: compatibility
     }}
  end

  @spec incompatible!(String.t(), map() | nil, atom()) :: t()
  def incompatible!(message, compatibility \\ nil, stage \\ :translation) do
    {:error, error} = incompatible(message, compatibility, stage)
    error
  end

  @spec wire(String.t()) :: {:error, t()}
  def wire(message),
    do: {:error, %__MODULE__{kind: :invalid_request, stage: :wire, message: message}}

  @spec wire!(String.t()) :: t()
  def wire!(message) do
    {:error, error} = wire(message)
    error
  end

  @spec new(map()) :: {:ok, t()} | {:error, t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, _kind} <- atom(attrs, :kind),
         {:ok, _stage} <- atom(attrs, :stage),
         :ok <- Backplane.AiProtocol.Validation.bounded_map(attrs[:details] || %{}),
         :ok <- Backplane.AiProtocol.Validation.bounded_map(attrs[:compatibility] || %{}) do
      error = struct(__MODULE__, Map.take(attrs, @keys))
      {:ok, %{error | details: attrs[:details] || %{}}}
    else
      {:error, %__MODULE__{}} = invalid -> invalid
      _ -> invalid("Invalid Error")
    end
  end

  @doc false
  def keys, do: @keys

  defp atom(attrs, key) do
    case Map.get(attrs, key) do
      value when is_atom(value) -> {:ok, value}
      _ -> {:error, invalid!("Error #{key} must be an atom")}
    end
  end
end
