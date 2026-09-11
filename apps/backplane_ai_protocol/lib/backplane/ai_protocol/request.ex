defmodule Backplane.AiProtocol.Request do
  @moduledoc """
  Portable caller intent.

  This struct never contains execution context. Provider state is represented as origin-bound
  input items, not trusted host credentials.
  """

  alias Backplane.AiProtocol.{Error, Message, ProviderState, ToolDefinition}

  @enforce_keys [:model, :input]
  defstruct [
    :model,
    :input,
    :tools,
    :settings,
    :output_constraints,
    :provider_state_references,
    :permitted_downgrades,
    correlation: %{},
    extensions: %{}
  ]

  @type t :: %__MODULE__{
          model: map() | String.t(),
          input: [Message.t() | ProviderState.t()],
          tools: [ToolDefinition.t()],
          settings: map() | nil,
          output_constraints: map() | nil,
          provider_state_references: [ProviderState.t()] | nil,
          permitted_downgrades: [String.t()] | nil,
          correlation: map(),
          extensions: map()
        }

  @keys [
    :model,
    :input,
    :tools,
    :settings,
    :output_constraints,
    :provider_state_references,
    :permitted_downgrades,
    :correlation,
    :extensions
  ]

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, model} <- model(Map.get(attrs, :model)),
         {:ok, input} <- input(Map.get(attrs, :input)),
         :ok <- tools(attrs[:tools]),
         :ok <- optional_map(attrs, :settings),
         :ok <- optional_map(attrs, :output_constraints),
         :ok <- optional_map(attrs, :correlation),
         :ok <- provider_state_references(attrs[:provider_state_references]),
         :ok <- downgrades(attrs[:permitted_downgrades]),
         :ok <- extensions(attrs[:extensions]) do
      {:ok,
       %__MODULE__{
         model: model,
         input: input,
         tools: attrs[:tools] || [],
         settings: attrs[:settings],
         output_constraints: attrs[:output_constraints],
         provider_state_references: attrs[:provider_state_references] || [],
         permitted_downgrades: attrs[:permitted_downgrades] || [],
         correlation: attrs[:correlation] || %{},
         extensions: attrs[:extensions] || %{}
       }}
    end
  end

  @doc false
  def keys, do: @keys

  defp model(%{} = model), do: {:ok, model}
  defp model(model) when is_binary(model) and model != "", do: {:ok, model}

  defp model(_value),
    do: {:error, Error.invalid!("Request model must be a selector map or non-empty string")}

  defp input(input) when is_list(input), do: input_items(input, [])
  defp input(_value), do: {:error, Error.invalid!("Request input must be a list")}

  defp input_items([], acc), do: {:ok, Enum.reverse(acc)}

  defp input_items([item | rest], acc) do
    result =
      cond do
        is_map(item) and Map.get(item, :role) != nil and Map.get(item, :content) != nil ->
          Message.new(item)

        is_map(item) and Map.get(item, :affinity) != nil ->
          ProviderState.new(item)

        true ->
          {:error, Error.invalid!("Request input item is invalid")}
      end

    case result do
      {:ok, item} -> input_items(rest, [item | acc])
      error -> error
    end
  end

  defp tools(nil), do: :ok

  defp tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, :ok, fn tool, :ok ->
      case ToolDefinition.new(tool) do
        {:ok, _tool} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp tools(_value), do: {:error, Error.invalid!("Request tools must be a list")}

  defp optional_map(attrs, key) do
    case Map.get(attrs, key) do
      nil -> :ok
      value when is_map(value) -> Backplane.AiProtocol.Validation.term(value)
      _ -> {:error, Error.invalid!("Request #{key} must be a map")}
    end
  end

  defp provider_state_references(nil), do: :ok

  defp provider_state_references(states) when is_list(states) do
    Enum.reduce_while(states, :ok, fn state, :ok ->
      case ProviderState.new(state) do
        {:ok, _state} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp provider_state_references(_value),
    do: {:error, Error.invalid!("Request provider_state_references must be a list")}

  defp downgrades(nil), do: :ok

  defp downgrades(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) and length(values) <= 64 do
      :ok
    else
      {:error, Error.invalid!("Request permitted_downgrades must be at most 64 named strings")}
    end
  end

  defp downgrades(_value),
    do: {:error, Error.invalid!("Request permitted_downgrades must be a list")}

  defp extensions(nil), do: :ok

  defp extensions(value) when is_map(value),
    do: Backplane.AiProtocol.Validation.bounded_map(value)

  defp extensions(_value), do: {:error, Error.invalid!("Request extensions must be a map")}
end
