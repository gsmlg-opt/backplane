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

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    {core_attrs, extension_attrs} = split_extensions(attrs)

    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(core_attrs, @keys),
         {:ok, type} <- type(Map.get(core_attrs, :type)),
         {:ok, block} <- build(type, core_attrs),
         :ok <- extensions(extension_attrs) do
      %{block | extensions: extension_attrs}
      |> then(&{:ok, &1})
    end
  end

  @doc false
  def keys, do: @keys

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

  defp build(:text, attrs), do: required_string(attrs, :text, :text)

  defp build(:reasoning, attrs) do
    with {:ok, data} <- required_bounded_value(attrs, :data),
         :ok <- optional_string(attrs, :reason) do
      {:ok, %__MODULE__{type: :reasoning, data: data, reason: attrs[:reason]}}
    end
  end

  defp build(:image, attrs) do
    with {:ok, data} <- required_bounded_value(attrs, :data),
         :ok <- optional_string(attrs, :reason) do
      {:ok, %__MODULE__{type: :image, data: data, reason: attrs[:reason]}}
    end
  end

  defp build(:tool_call, attrs) do
    with {:ok, tool_call} <- Backplane.AiProtocol.ToolCall.new(Map.get(attrs, :tool_call, %{})) do
      {:ok, %__MODULE__{type: :tool_call, tool_call: tool_call}}
    end
  end

  defp build(:refusal, attrs), do: required_string(attrs, :text, :refusal)

  defp build(:provider_state, attrs) do
    case Backplane.AiProtocol.ProviderState.new(Map.get(attrs, :state, %{})) do
      {:ok, state} ->
        {:ok, %__MODULE__{type: :provider_state, state: state}}

      {:error, %Error{message: message}} ->
        {:error, Error.invalid!("Provider state content: " <> message)}
    end
  end

  defp required_string(attrs, key, type) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" ->
        with :ok <- Backplane.AiProtocol.Validation.term(value) do
          {:ok, %__MODULE__{type: type, text: value, reason: attrs[:reason]}}
        end

      _ ->
        {:error, Error.invalid!("Content #{key} must be a non-empty string")}
    end
  end

  defp required_bounded_value(attrs, key) do
    case Map.get(attrs, key) do
      nil ->
        {:error, Error.invalid!("Content #{key} is required")}

      value ->
        with :ok <- Backplane.AiProtocol.Validation.term(value) do
          {:ok, value}
        end
    end
  end

  defp optional_string(attrs, key) do
    case Map.get(attrs, key) do
      nil -> :ok
      value when is_binary(value) -> Backplane.AiProtocol.Validation.term(value)
      _ -> {:error, Error.invalid!("Content #{key} must be a string")}
    end
  end

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
