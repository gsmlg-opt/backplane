defmodule Backplane.AiProtocol.Serialization do
  @moduledoc """
  JSON encoding for canonical portable structures.

  Structs are rejected rather than guessed, so a caller explicitly marks public structs as
  serializable. Secrets and opaque state are excluded from this generic encoding.
  """

  alias Backplane.AiProtocol.Error

  @opaque_structs [Backplane.AiProtocol.ProviderState, Backplane.AiProtocol.ContentBlock]

  @json_lib Mix.Project.config()[:json_library] || :"Elixir.Jason"

  @spec to_json(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def to_json(value) when is_binary(value) do
    @json_lib.encode(value)
  end

  def to_json(%module{}) when module in @opaque_structs do
    {:error,
     Error.invalid!(
       "#{module} cannot be serialized generically because it may contain opaque data"
     )}
  end

  def to_json(value) do
    with {:ok, normalized} <- normalize(value) do
      @json_lib.encode(normalized)
    end
  end

  @spec from_json(String.t()) :: {:ok, term()} | {:error, Error.t()}
  def from_json(json) when is_binary(json) do
    case @json_lib.decode(json) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, Error.invalid!("Invalid JSON")}
    end
  end

  def from_json(value) when is_map(value), do: {:ok, value}

  @spec decode_and_validate(term(), (map() -> {:ok, term()} | {:error, Error.t()})) ::
          {:ok, term()} | {:error, Error.t()}
  def decode_and_validate(json, validator) when is_binary(json) and is_function(validator, 1) do
    with {:ok, value} <- from_json(json),
         :ok <- Backplane.AiProtocol.Validation.term(value) do
      validator.(value)
    end
  end

  def decode_and_validate(_json, _validator),
    do: {:error, Error.invalid!("JSON payload must be a string")}

  defp normalize(nil), do: {:ok, nil}
  defp normalize(true), do: {:ok, true}
  defp normalize(false), do: {:ok, false}
  defp normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize(value) when is_integer(value), do: {:ok, value}
  defp normalize(value) when is_float(value), do: {:ok, value}
  defp normalize(value) when is_binary(value), do: {:ok, value}

  defp normalize(value) when is_map(value) do
    Enum.reduce_while(Map.to_list(value), {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) ->
        case normalize(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(Map.delete(acc, key), key, value)}}
          error -> {:halt, error}
        end

      {key, _value}, {:ok, acc} when is_atom(key) ->
        string_key = Atom.to_string(key)

        case normalize(Map.fetch!(value, key)) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, string_key, normalized)}}
          error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, Error.invalid!("JSON map keys must be strings or atoms")}}
    end)
  end

  defp normalize(value) when is_list(value), do: list(value, [])

  defp normalize(%module{}),
    do: {:error, Error.invalid!("Unsupported struct: #{inspect(module)}")}

  defp normalize(%Date{} = value), do: {:ok, Date.to_iso8601(value)}
  defp normalize(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}
  defp normalize(%NaiveDateTime{} = value), do: {:ok, NaiveDateTime.to_iso8601(value)}

  defp normalize(value) when is_tuple(value),
    do: {:error, Error.invalid!("JSON tuples are not supported")}

  defp normalize(_value), do: {:error, Error.invalid!("Unsupported JSON value")}

  defp list([], acc), do: {:ok, Enum.reverse(acc)}

  defp list([value | rest], acc) do
    case normalize(value) do
      {:ok, normalized} -> list(rest, [normalized | acc])
      error -> error
    end
  end
end
