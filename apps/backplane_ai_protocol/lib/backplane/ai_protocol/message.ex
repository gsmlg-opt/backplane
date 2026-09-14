defmodule Backplane.AiProtocol.Message do
  @moduledoc """
  One ordered protocol item with preserved role and content order.
  """

  alias Backplane.AiProtocol.{ContentBlock, Error}

  @enforce_keys [:role, :content]
  defstruct [:role, :content, :tool_call_id, :status, extensions: %{}]

  @type role :: :system | :developer | :user | :assistant | :tool

  @type status :: :success | :error | nil

  @type t :: %__MODULE__{
          role: role(),
          content: [ContentBlock.t()],
          tool_call_id: String.t() | nil,
          status: status(),
          extensions: map()
        }

  @keys [:role, :content, :tool_call_id, :status, :extensions]

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = message), do: message |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, role} <- role(Map.get(attrs, :role)),
         {:ok, content} <- content(Map.get(attrs, :content)),
         :ok <- tool_result(attrs, role),
         :ok <- status(attrs[:status]),
         :ok <- extensions(attrs[:extensions]) do
      {:ok,
       %__MODULE__{
         role: role,
         content: content,
         tool_call_id: attrs[:tool_call_id],
         status: attrs[:status],
         extensions: attrs[:extensions] || %{}
       }}
    end
  end

  @doc false
  def keys, do: @keys

  defp role(value) when value in [:system, :developer, :user, :assistant, :tool], do: {:ok, value}
  defp role(_value), do: {:error, Error.invalid!("Message role must be a known atom")}

  defp content(value) when is_list(value), do: blocks(value, [])
  defp content(_value), do: {:error, Error.invalid!("Message content must be a list")}

  defp blocks([], acc), do: {:ok, Enum.reverse(acc)}

  defp blocks([block | rest], acc) do
    case ContentBlock.new(block) do
      {:ok, block} -> blocks(rest, [block | acc])
      error -> error
    end
  end

  defp tool_result(attrs, :tool) do
    case attrs[:tool_call_id] do
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, Error.invalid!("Tool result requires tool_call_id")}
    end
  end

  defp tool_result(_attrs, _role), do: :ok

  defp status(value) when value in [nil, :success, :error], do: :ok
  defp status(_value), do: {:error, Error.invalid!("Tool result status must be success or error")}

  defp extensions(nil), do: :ok

  defp extensions(extensions) do
    Enum.reduce_while(extensions, :ok, fn
      {name, value}, :ok ->
        case Backplane.AiProtocol.Validation.bounded_extension(name, value) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, Error.invalid!("Extensions must be a string-keyed map")}}
    end)
  end
end
