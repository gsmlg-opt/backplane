defmodule Backplane.AiProtocol.Response do
  @moduledoc """
  Complete or partial provider response.

  Output completeness is independent of protocol terminal state and trailing usage.
  """

  alias Backplane.AiProtocol.{Error, Usage}

  @enforce_keys [:output, :stop_reason, :completeness]
  defstruct [
    :output,
    :stop_reason,
    :completeness,
    :usage,
    :resolved_model,
    warnings: [],
    extensions: %{}
  ]

  @type stop_reason ::
          :stop
          | :tool_use
          | :max_output_tokens
          | :refusal
          | :safety
          | :cancelled
          | :unknown
          | atom()

  @type completeness :: :complete | :partial | :unknown

  @type t :: %__MODULE__{
          output: [term()],
          stop_reason: stop_reason(),
          completeness: completeness(),
          usage: Usage.t() | nil,
          resolved_model: map() | String.t() | nil,
          warnings: [map() | String.t()],
          extensions: map()
        }

  @keys [
    :output,
    :stop_reason,
    :completeness,
    :usage,
    :resolved_model,
    :warnings,
    :extensions
  ]

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, output} <- output(Map.get(attrs, :output)),
         {:ok, _stop_reason} <- stop_reason(Map.get(attrs, :stop_reason)),
         {:ok, _completeness} <- completeness(Map.get(attrs, :completeness)),
         {:ok, usage} <- usage(attrs[:usage]),
         :ok <- warnings(attrs[:warnings]),
         :ok <- extensions(attrs[:extensions]) do
      {:ok,
       %__MODULE__{
         output: output,
         stop_reason: attrs[:stop_reason],
         completeness: attrs[:completeness],
         usage: usage,
         resolved_model: attrs[:resolved_model],
         warnings: attrs[:warnings] || [],
         extensions: attrs[:extensions] || %{}
       }}
    end
  end

  @doc false
  def keys, do: @keys

  defp output(output) when is_list(output) do
    case Backplane.AiProtocol.Validation.term(output) do
      :ok -> {:ok, output}
      error -> error
    end
  end

  defp output(_value), do: {:error, Error.invalid!("Response output must be a list")}

  defp stop_reason(value) when is_atom(value), do: {:ok, value}
  defp stop_reason(_value), do: {:error, Error.invalid!("Response stop_reason must be an atom")}

  defp completeness(value) when value in [:complete, :partial, :unknown], do: {:ok, value}

  defp completeness(_value),
    do: {:error, Error.invalid!("Response completeness must be complete, partial, or unknown")}

  defp usage(nil), do: {:ok, nil}
  defp usage(%Usage{} = usage), do: {:ok, usage}

  defp usage(attrs) when is_map(attrs) do
    case Usage.new(attrs) do
      {:ok, usage} ->
        {:ok, usage}

      {:error, %Error{message: message}} ->
        {:error, Error.invalid!("Response usage: " <> message)}

      _ ->
        {:error, Error.invalid!("Response usage is invalid")}
    end
  end

  defp usage(_value), do: {:error, Error.invalid!("Response usage must be a Usage")}

  defp warnings(nil), do: :ok

  defp warnings(warnings) when is_list(warnings),
    do: Backplane.AiProtocol.Validation.term(warnings)

  defp warnings(_value), do: {:error, Error.invalid!("Response warnings must be a list")}

  defp extensions(nil), do: :ok

  defp extensions(value) when is_map(value),
    do: Backplane.AiProtocol.Validation.bounded_map(value)

  defp extensions(_value), do: {:error, Error.invalid!("Response extensions must be a map")}
end
