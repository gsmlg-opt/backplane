defmodule Backplane.AiProtocol.Translation do
  @moduledoc """
  Pure preflight over a request and capability snapshots.

  Returns an executable plan or structured refusal. No request emission occurs in this module.
  """

  alias Backplane.AiProtocol.Error
  alias Backplane.AiProtocol.TranslationPlan

  @downgrade_rules %{
    "image" => :image,
    "image_to_text" => :image,
    "reasoning" => :reasoning,
    "reasoning_to_text" => :reasoning,
    "tool_calls" => :tool_calls,
    "provider_state" => :provider_state
  }

  @spec plan(Backplane.AiProtocol.Request.t(), map(), map(), map()) ::
          {:ok, TranslationPlan.t()} | {:error, Error.t()}
  def plan(%Backplane.AiProtocol.Request{} = request, source, target, policy)
      when is_map(source) and is_map(target) and is_map(policy) do
    source_caps = Map.get(source, :capabilities, %{})
    target_caps = Map.get(target, :capabilities, %{})

    with :ok <- validate_downgrades(request.permitted_downgrades),
         {:ok, diagnostics, downgraded} <-
           check_fields(request, source_caps, target_caps, request.permitted_downgrades),
         :ok <- check_provider_state(request, target) do
      {:ok,
       %TranslationPlan{
         request: request,
         executable: true,
         diagnostics: diagnostics,
         downgrades: downgraded
       }}
    end
  end

  def plan(_request, _source, _target, _policy),
    do: {:error, Error.invalid!("Translation.plan requires a Request struct")}

  @spec check_fields(
          Backplane.AiProtocol.Request.t(),
          map(),
          map(),
          [String.t()]
        ) :: {:ok, [map()], [String.t()]} | {:error, Error.t()}
  defp check_fields(request, source_caps, target_caps, permitted_downgrades) do
    requested_fields = requested_fields(request)

    requested_fields
    |> Enum.reduce_while({:ok, [], []}, fn field, {:ok, diagnostics, downgraded} ->
      source_support = capability(source_caps, field)
      target_support = capability(target_caps, field)

      field_name = Atom.to_string(field)

      cond do
        source_support != :supported ->
          {:halt, {:error, Error.incompatible!("Source does not support #{field}")}}

        target_support == :supported ->
          {:cont, {:ok, diagnostics, downgraded}}

        field in Enum.map(permitted_downgrades || [], &Map.get(@downgrade_rules, &1)) ->
          diagnostic = %{
            field: field_name,
            reason: "downgraded_by_policy",
            source_support: Atom.to_string(source_support),
            target_support: Atom.to_string(target_support)
          }

          {:cont, {:ok, [diagnostic | diagnostics], [field_name | downgraded]}}

        true ->
          {:halt,
           {:error,
            Error.incompatible!("Target does not support #{field}", %{
              "field" => Atom.to_string(field)
            })}}
      end
    end)
    |> case do
      {:ok, diagnostics, downgraded} ->
        {:ok, Enum.reverse(diagnostics), Enum.reverse(downgraded)}

      error ->
        error
    end
  end

  defp requested_fields(%Backplane.AiProtocol.Request{} = request) do
    message_fields = Enum.flat_map(request.input, &item_fields/1)

    tool_fields =
      if request.tools != [] do
        [:tool_calls]
      else
        []
      end

    Enum.uniq(message_fields ++ tool_fields)
  end

  defp item_fields(%Backplane.AiProtocol.Message{content: content}) do
    Enum.flat_map(content, &block_fields/1)
  end

  defp item_fields(%Backplane.AiProtocol.ProviderState{}), do: [:provider_state]
  defp item_fields(_item), do: []

  defp block_fields(%Backplane.AiProtocol.ContentBlock{type: :text}), do: [:text]
  defp block_fields(%Backplane.AiProtocol.ContentBlock{type: :image}), do: [:image]
  defp block_fields(%Backplane.AiProtocol.ContentBlock{type: :reasoning}), do: [:reasoning]
  defp block_fields(%Backplane.AiProtocol.ContentBlock{type: :tool_call}), do: [:tool_calls]

  defp block_fields(%Backplane.AiProtocol.ContentBlock{type: :refusal}), do: [:refusal]
  defp block_fields(%Backplane.AiProtocol.ContentBlock{type: :provider_state}), do: [:provider_state]
  defp block_fields(_block), do: []

  defp capability(caps, field) do
    cond do
      Map.get(caps, field) != nil -> Map.get(caps, field)
      Map.get(caps, Atom.to_string(field)) != nil -> Map.get(caps, Atom.to_string(field))
      true -> :unsupported
    end
  end

  defp validate_downgrades(nil), do: :ok

  defp validate_downgrades(downgrades) when is_list(downgrades) do
    unknown = Enum.filter(downgrades, &not Map.has_key?(@downgrade_rules, &1))

    if unknown == [],
      do: :ok,
      else: {:error, Error.incompatible!("Unknown downgrade rule: #{hd(unknown)}")}
  end

  defp check_provider_state(request, target) do
    target_protocol = Map.get(target, :protocol)

    request.input
    |> Enum.filter(&match?(%Backplane.AiProtocol.ProviderState{}, &1))
    |> Enum.reduce_while(:ok, fn state, :ok ->
      if state.source_protocol == target_protocol do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          Error.incompatible!(
            "Provider state from #{state.source_protocol} cannot be used with target #{target_protocol}",
            %{"field" => "affinity"}
          )}}
      end
    end)
  end
end
