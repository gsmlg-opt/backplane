defmodule Backplane.AiProtocol.Serialization do
  @moduledoc """
  Safe JSON encoding for portable values and explicitly approved public projections.

  Provider state, reasoning state, and execution context require protocol-specific encoders and
  are rejected here even when nested.
  """

  alias Backplane.AiProtocol.{
    ContentBlock,
    Error,
    Message,
    Request,
    ToolCall,
    ToolDefinition,
    Usage,
    Validation
  }

  @default_max_encoded_bytes 2_097_152
  @denied_structs [
    Backplane.AiProtocol.ExecutionContext,
    Backplane.AiProtocol.ProviderState,
    Backplane.AiProtocol.Affinity
  ]

  @spec to_json(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def to_json(value) do
    with {:ok, normalized} <- normalize(value), {:ok, json} <- encode(normalized), do: {:ok, json}
  end

  @spec from_json(String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def from_json(json, opts \\ [])

  def from_json(json, opts) when is_binary(json) do
    max_bytes = Keyword.get(opts, :max_encoded_bytes, @default_max_encoded_bytes)

    cond do
      byte_size(json) > max_bytes ->
        {:error, Error.invalid!("Encoded JSON exceeds #{max_bytes} bytes")}

      not String.valid?(json) ->
        {:error, Error.invalid!("Invalid UTF-8 JSON")}

      true ->
        case Jason.decode(json) do
          {:ok, value} -> {:ok, value}
          _ -> {:error, Error.invalid!("Invalid JSON")}
        end
    end
  end

  def from_json(_value, _opts), do: {:error, Error.invalid!("JSON payload must be a string")}

  @spec decode_and_validate(term(), (map() -> {:ok, term()} | {:error, Error.t()}), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def decode_and_validate(json, validator, opts \\ [])

  def decode_and_validate(json, validator, opts)
      when is_binary(json) and is_function(validator, 1) do
    with {:ok, value} <- from_json(json, opts),
         :ok <- Validation.term(value, Keyword.get(opts, :limits, %{})) do
      validator.(value)
    end
  rescue
    _ -> {:error, Error.invalid!("JSON validation failed")}
  end

  def decode_and_validate(_json, _validator, _opts),
    do: {:error, Error.invalid!("JSON payload must be a string")}

  defp normalize(%module{}) when module in @denied_structs,
    do: {:error, Error.invalid!("#{module} cannot be serialized generically")}

  defp normalize(%ContentBlock{type: type}) when type in [:reasoning, :provider_state],
    do: {:error, Error.invalid!("Opaque #{type} content cannot be serialized generically")}

  defp normalize(%Request{} = value), do: project(value, Request.keys())
  defp normalize(%Message{} = value), do: project(value, Message.keys())
  defp normalize(%ContentBlock{} = value), do: project(value, ContentBlock.keys())

  defp normalize(%ToolCall{} = value) do
    raw_arguments =
      case value.raw_arguments do
        {:json, json} -> %{"encoding" => "json", "value" => json}
        {:structured, structured} -> %{"encoding" => "structured", "value" => structured}
      end

    value
    |> Map.take(ToolCall.keys())
    |> Map.put(:raw_arguments, raw_arguments)
    |> Enum.reject(fn {_key, item} -> is_nil(item) end)
    |> Map.new()
    |> normalize()
  end

  defp normalize(%ToolDefinition{} = value), do: project(value, ToolDefinition.keys())
  defp normalize(%Usage{} = value), do: project(value, Usage.keys())

  defp normalize(%module{}),
    do: {:error, Error.invalid!("Unsupported struct: #{inspect(module)}")}

  defp normalize(nil), do: {:ok, nil}
  defp normalize(true), do: {:ok, true}
  defp normalize(false), do: {:ok, false}
  defp normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize(value) when is_integer(value) or is_float(value) or is_binary(value),
    do: {:ok, value}

  defp normalize(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      with {:ok, string_key} <- normalize_key(key),
           false <- Map.has_key?(acc, string_key),
           {:ok, normalized} <- normalize(item) do
        {:cont, {:ok, Map.put(acc, string_key, normalized)}}
      else
        true ->
          {:halt, {:error, Error.invalid!("Duplicate normalized JSON key: #{string_key(key)}")}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
  end

  defp normalize(value) when is_list(value), do: normalize_list(value, [])
  defp normalize(_value), do: {:error, Error.invalid!("Unsupported JSON value")}

  defp project(struct, keys) do
    struct
    |> Map.take(keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> normalize()
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, Error.invalid!("JSON map keys must be strings or atoms")}
  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: to_string(key)
  defp normalize_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_list([value | rest], acc) do
    case normalize(value) do
      {:ok, normalized} -> normalize_list(rest, [normalized | acc])
      error -> error
    end
  end

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      _ -> {:error, Error.invalid!("JSON encoding failed")}
    end
  rescue
    _ -> {:error, Error.invalid!("JSON encoding failed")}
  end
end
