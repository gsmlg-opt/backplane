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

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs, opts \\ []) when is_map(attrs) do
    limits = Keyword.get(opts, :limits, %{})

    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, model} <- model(Map.get(attrs, :model)),
         {:ok, input} <- input(Map.get(attrs, :input), opts),
         {:ok, tools} <- tools(attrs[:tools], opts),
         :ok <- optional_map(attrs, :settings, limits),
         :ok <- optional_map(attrs, :output_constraints, limits),
         :ok <- optional_map(attrs, :correlation, limits),
         {:ok, provider_state_references} <-
           provider_state_references(attrs[:provider_state_references], opts),
         :ok <- downgrades(attrs[:permitted_downgrades]),
         :ok <- extensions(attrs[:extensions], limits) do
      {:ok,
       %__MODULE__{
         model: model,
         input: input,
         tools: tools,
         settings: attrs[:settings],
         output_constraints: attrs[:output_constraints],
         provider_state_references: provider_state_references,
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

  defp input(input, opts) when is_list(input), do: input_items(input, [], opts)
  defp input(_value, _opts), do: {:error, Error.invalid!("Request input must be a list")}

  defp input_items([], acc, _opts), do: {:ok, Enum.reverse(acc)}

  defp input_items([item | rest], acc, opts) do
    result =
      cond do
        is_map(item) and Map.get(item, :role) != nil and Map.get(item, :content) != nil ->
          Message.new(item, opts)

        is_map(item) and Map.get(item, :affinity) != nil ->
          ProviderState.new(item, opts)

        true ->
          {:error, Error.invalid!("Request input item is invalid")}
      end

    case result do
      {:ok, item} -> input_items(rest, [item | acc], opts)
      error -> error
    end
  end

  defp tools(nil, _opts), do: {:ok, []}

  defp tools(tools, opts) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      case ToolDefinition.new(tool, opts) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp tools(_value, _opts), do: {:error, Error.invalid!("Request tools must be a list")}

  defp optional_map(attrs, key, limits) do
    case Map.get(attrs, key) do
      nil -> :ok
      value when is_map(value) -> Backplane.AiProtocol.Validation.term(value, limits)
      _ -> {:error, Error.invalid!("Request #{key} must be a map")}
    end
  end

  defp provider_state_references(nil, _opts), do: {:ok, []}

  defp provider_state_references(states, opts) when is_list(states) do
    Enum.reduce_while(states, {:ok, []}, fn state, {:ok, acc} ->
      case ProviderState.new(state, opts) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp provider_state_references(_value, _opts),
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

  defp extensions(nil, _limits), do: :ok

  defp extensions(value, limits) when is_map(value),
    do: Backplane.AiProtocol.Validation.bounded_map(value, limits)

  defp extensions(_value, _limits),
    do: {:error, Error.invalid!("Request extensions must be a map")}
end
