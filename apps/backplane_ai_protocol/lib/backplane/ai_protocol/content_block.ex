defmodule Backplane.AiProtocol.ContentBlock do
  @moduledoc """
  Typed, ordered content.

  Opaque reasoning and provider state are preserved as provenance-tagged values; they are never
  converted into display text.
  """

  alias Backplane.AiProtocol.Error

  @enforce_keys [:type]
  defstruct [:type, :text, :data, :tool_call, :reason, :state, extensions: %{}]

  @type kind :: :text | :image | :reasoning | :tool_call | :refusal | :provider_state

  @type t :: %__MODULE__{
          type: kind(),
          text: String.t() | nil,
          data: term() | nil,
          tool_call: Backplane.AiProtocol.ToolCall.t() | nil,
          reason: String.t() | nil,
          state: map() | nil,
          extensions: map()
        }

  @keys [:type, :text, :data, :tool_call, :reason, :state, :extensions]

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs, opts \\ [])
  def new(%__MODULE__{} = block, opts), do: block |> Map.from_struct() |> new(opts)

  def new(attrs, opts) when is_map(attrs) do
    limits = Keyword.get(opts, :limits, %{})

    with :ok <- reject_core_collisions(attrs),
         {core_attrs, extension_attrs} = split_extensions(attrs),
         :ok <- Backplane.AiProtocol.Validation.reject_unknown(core_attrs, @keys),
         {:ok, type} <- type(Map.get(core_attrs, :type)),
         {:ok, block} <- build(type, core_attrs, opts),
         :ok <- extensions(extension_attrs, limits) do
      %{block | extensions: extension_attrs}
      |> then(&{:ok, &1})
    end
  end

  @doc false
  def keys, do: @keys

  defp reject_core_collisions(attrs) do
    case Enum.find(@keys, &(Map.has_key?(attrs, &1) and Map.has_key?(attrs, Atom.to_string(&1)))) do
      nil -> :ok
      key -> {:error, Error.invalid!("Duplicate normalized field: #{key}")}
    end
  end

  defp type(value)
       when value in [:text, :image, :reasoning, :tool_call, :refusal, :provider_state],
       do: {:ok, value}

  defp type(_value), do: {:error, Error.invalid!("Content type must be a known atom")}

  defp split_extensions(attrs) do
    core = core_attrs(attrs)
    core_keys = core_keys(attrs)
    discovered = Map.filter(attrs, fn {key, _value} -> key not in core_keys end)
    explicit = Map.get(core, :extensions, %{})
    extensions = if is_map(explicit), do: Map.merge(explicit, discovered), else: explicit

    {Map.delete(core, :extensions), extensions}
  end

  defp core_keys(attrs) do
    Enum.flat_map(Map.keys(attrs), fn
      key when is_atom(key) ->
        if key in @keys, do: [key], else: []

      key when is_binary(key) ->
        if Map.has_key?(core_names(), key), do: [key], else: []

      _key ->
        []
    end)
  end

  defp core_names, do: Map.new(@keys, &{Atom.to_string(&1), &1})

  defp core_attrs(attrs) do
    Enum.reduce(@keys, %{}, fn key, acc ->
      case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), :__backplane_missing__)) do
        :__backplane_missing__ -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp build(:text, attrs, opts), do: required_string(attrs, :text, :text, opts)

  defp build(:reasoning, attrs, opts) do
    with {:ok, data} <- required_bounded_value(attrs, :data, opts),
         :ok <- optional_string(attrs, :reason, opts) do
      {:ok, %__MODULE__{type: :reasoning, data: data, reason: attrs[:reason]}}
    end
  end

  defp build(:image, attrs, opts) do
    with {:ok, data} <- required_bounded_value(attrs, :data, opts),
         :ok <- optional_string(attrs, :reason, opts) do
      {:ok, %__MODULE__{type: :image, data: data, reason: attrs[:reason]}}
    end
  end

  defp build(:tool_call, attrs, opts) do
    with {:ok, tool_call} <-
           Backplane.AiProtocol.ToolCall.new(Map.get(attrs, :tool_call, %{}), opts) do
      {:ok, %__MODULE__{type: :tool_call, tool_call: tool_call}}
    end
  end

  defp build(:refusal, attrs, opts), do: required_string(attrs, :text, :refusal, opts)

  defp build(:provider_state, attrs, opts) do
    case Backplane.AiProtocol.ProviderState.new(Map.get(attrs, :state, %{}), opts) do
      {:ok, state} ->
        {:ok, %__MODULE__{type: :provider_state, state: state}}

      {:error, %Error{message: message}} ->
        {:error, Error.invalid!("Provider state content: " <> message)}
    end
  end

  defp required_string(attrs, key, type, opts) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" ->
        with :ok <- Backplane.AiProtocol.Validation.term(value, Keyword.get(opts, :limits, %{})) do
          {:ok, %__MODULE__{type: type, text: value, reason: attrs[:reason]}}
        end

      _ ->
        {:error, Error.invalid!("Content #{key} must be a non-empty string")}
    end
  end

  defp required_bounded_value(attrs, key, opts) do
    case Map.get(attrs, key) do
      nil ->
        {:error, Error.invalid!("Content #{key} is required")}

      value ->
        with :ok <- Backplane.AiProtocol.Validation.term(value, Keyword.get(opts, :limits, %{})) do
          {:ok, value}
        end
    end
  end

  defp optional_string(attrs, key, opts) do
    case Map.get(attrs, key) do
      nil ->
        :ok

      value when is_binary(value) ->
        Backplane.AiProtocol.Validation.term(value, Keyword.get(opts, :limits, %{}))

      _ ->
        {:error, Error.invalid!("Content #{key} must be a string")}
    end
  end

  defp extensions(nil, _limits), do: :ok

  defp extensions(extensions, limits) do
    Enum.reduce_while(extensions, :ok, fn
      {name, value}, :ok ->
        case Backplane.AiProtocol.Validation.bounded_extension(name, value, limits) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, Error.invalid!("Extensions must be a string-keyed map")}}
    end)
  end
end
