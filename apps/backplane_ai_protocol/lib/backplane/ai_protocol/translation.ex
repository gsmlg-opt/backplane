defmodule Backplane.AiProtocol.Translation do
  @moduledoc """
  Strict, pure translation preflight.

  Missing capability information is `:unknown`, never implicit support. Downgrades require both
  caller consent and a trusted host rule containing an executable operation.
  """

  alias Backplane.AiProtocol.{
    Capability,
    ContentBlock,
    Error,
    Message,
    ProviderState,
    Request,
    TranslationPlan
  }

  @spec plan(Request.t(), map(), map(), map()) ::
          {:ok, TranslationPlan.t()} | {:error, Error.t()}
  def plan(%Request{} = request, source, target, policy)
      when is_map(source) and is_map(target) and is_map(policy) do
    with :ok <- validate_permitted(request.permitted_downgrades, policy),
         {:ok, requirements} <- requested_requirements(request),
         {:ok, diagnostics, downgrades, operations} <-
           check_requirements(requirements, source, target, request.permitted_downgrades, policy),
         :ok <- check_provider_state(request, source, target) do
      {:ok,
       %TranslationPlan{
         request: request,
         executable: true,
         diagnostics: diagnostics,
         downgrades: downgrades,
         operations: operations,
         source: identity(source),
         target: identity(target)
       }}
    end
  end

  def plan(_request, _source, _target, _policy),
    do: {:error, Error.invalid!("Translation.plan requires a Request struct and maps")}

  defp requested_requirements(request) do
    base = Enum.flat_map(request.input, &item_requirements/1)
    tools = if request.tools == [], do: [], else: [%{field: "tool_calls", path: "tools"}]
    settings = map_requirements(request.settings, "settings")
    outputs = map_requirements(request.output_constraints, "output_constraints")

    references =
      if request.provider_state_references == [],
        do: [],
        else: [%{field: "provider_state", path: "provider_state_references"}]

    critical_extensions = map_requirements(request.extensions, "extensions")

    {:ok,
     Enum.uniq_by(
       base ++ tools ++ settings ++ outputs ++ references ++ critical_extensions,
       & &1.path
     )}
  end

  defp validate_permitted(permitted, policy) do
    rules = value(policy, :downgrade_rules) || %{}

    case Enum.find(permitted || [], fn id -> not Map.has_key?(rules, id) end) do
      nil -> :ok
      id -> {:error, Error.incompatible!("Unknown or unavailable downgrade rule: #{id}")}
    end
  end

  defp item_requirements(%Message{role: role, content: content, tool_call_id: call_id}) do
    role_requirement = %{field: "role_#{role}", path: "input.role.#{role}"}
    result = if call_id, do: [%{field: "tool_results", path: "input.tool_result"}], else: []
    [role_requirement | result ++ Enum.flat_map(content, &block_requirements/1)]
  end

  defp item_requirements(%ProviderState{}),
    do: [%{field: "provider_state", path: "input.provider_state"}]

  defp item_requirements(_), do: []

  defp block_requirements(%ContentBlock{type: type}) do
    [%{field: block_field(type), path: "input.content.#{type}"}]
  end

  defp block_requirements(_), do: []
  defp block_field(:tool_call), do: "tool_calls"
  defp block_field(type), do: Atom.to_string(type)

  defp map_requirements(nil, _prefix), do: []
  defp map_requirements(map, _prefix) when map == %{}, do: []

  defp map_requirements(map, prefix) do
    Enum.map(map, fn {key, _value} ->
      name = to_string(key)
      %{field: "#{prefix}_#{name}", path: "#{prefix}.#{name}"}
    end)
  end

  defp check_requirements(requirements, source, target, permitted, policy) do
    source_caps = value(source, :capabilities) || %{}
    target_caps = value(target, :capabilities) || %{}

    Enum.reduce_while(requirements, {:ok, [], [], []}, fn requirement,
                                                          {:ok, diagnostics, rules, operations} ->
      source_support = capability(source_caps, requirement.field)
      target_support = capability(target_caps, requirement.field)

      cond do
        source_support != :supported ->
          {:halt,
           incompatible(requirement, "source_#{source_support}", source_support, target_support)}

        target_support == :supported ->
          {:cont, {:ok, diagnostics, rules, operations}}

        true ->
          case permitted_rule(requirement, permitted || [], policy) do
            {:ok, rule} ->
              diagnostic = %{
                "field_path" => requirement.path,
                "reason" => "downgraded_by_policy",
                "rule_id" => rule.id,
                "rule_revision" => rule.revision,
                "requested" => requirement.field,
                "effective" => rule.effective,
                "source" => identity(source),
                "target" => identity(target)
              }

              {:cont,
               {:ok, [diagnostic | diagnostics], [rule.id | rules], [rule.operation | operations]}}

            :error ->
              {:halt,
               incompatible(
                 requirement,
                 "target_#{target_support}",
                 source_support,
                 target_support
               )}
          end
      end
    end)
    |> case do
      {:ok, diagnostics, rules, operations} ->
        {:ok, Enum.reverse(diagnostics), Enum.reverse(rules), Enum.reverse(operations)}

      error ->
        error
    end
  end

  defp permitted_rule(requirement, permitted, policy) do
    rules = value(policy, :downgrade_rules) || %{}
    denied = MapSet.new(value(policy, :denied_downgrades) || [])

    Enum.find_value(permitted, :error, fn id ->
      rule = Map.get(rules, id) || Map.get(rules, to_string(id))

      if is_map(rule) and not MapSet.member?(denied, id) and
           to_string(value(rule, :field)) == requirement.field and
           is_binary(value(rule, :revision)) and is_map(value(rule, :operation)) do
        {:ok,
         %{
           id: to_string(id),
           revision: value(rule, :revision),
           operation: value(rule, :operation),
           effective: value(rule, :effective)
         }}
      end
    end)
  end

  defp incompatible(requirement, reason, source_support, target_support) do
    {:error,
     Error.incompatible!("Translation cannot preserve #{requirement.path}", %{
       "field" => requirement.field,
       "field_path" => requirement.path,
       "reason" => reason,
       "source_support" => Atom.to_string(source_support),
       "target_support" => Atom.to_string(target_support)
     })}
  end

  defp capability(caps, field) do
    atom_value =
      Enum.find_value(caps, fn
        {key, value} when is_atom(key) -> if Atom.to_string(key) == field, do: value
        _ -> nil
      end)

    case Map.get(caps, field, atom_value) do
      %Capability{state: state} -> state
      state when state in [:supported, :unsupported, :unknown] -> state
      nil -> :unknown
      _ -> :unknown
    end
  end

  defp check_provider_state(request, source, target) do
    request
    |> provider_states()
    |> Enum.reduce_while(:ok, fn state, :ok ->
      case compatible_state?(state, source, target) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp provider_states(request) do
    input = Enum.flat_map(request.input, &states_from_item/1)
    input ++ request.provider_state_references
  end

  defp states_from_item(%ProviderState{} = state), do: [state]

  defp states_from_item(%Message{content: content}),
    do: Enum.flat_map(content, &states_from_block/1)

  defp states_from_item(_), do: []

  defp states_from_block(%ContentBlock{type: :provider_state, state: %ProviderState{} = state}),
    do: [state]

  defp states_from_block(_), do: []

  defp compatible_state?(state, source, target) do
    affinity = state.affinity

    with :ok <-
           equal(state.source_profile, affinity.profile, "source_profile", "affinity.profile"),
         :ok <-
           equal(state.source_protocol, affinity.protocol, "source_protocol", "affinity.protocol"),
         :ok <- required_target(target, :profile, affinity.profile),
         :ok <- required_target(target, :protocol, affinity.protocol),
         :ok <- optional_target(target, :endpoint, affinity.endpoint),
         :ok <- optional_target(target, :account, affinity.account),
         :ok <- optional_target(target, :workspace, affinity.workspace),
         :ok <- optional_target(target, :model, affinity.model),
         :ok <- optional_source(source, :profile, state.source_profile),
         :ok <- optional_source(source, :protocol, state.source_protocol) do
      :ok
    end
  end

  defp required_target(target, key, expected) when is_binary(expected),
    do: equal(value(target, key), expected, "target.#{key}", "affinity.#{key}")

  defp required_target(_target, key, _expected),
    do: affinity_error("affinity.#{key}", "missing_required_binding")

  defp optional_target(_target, _key, nil), do: :ok

  defp optional_target(target, key, expected),
    do: equal(value(target, key), expected, "target.#{key}", "affinity.#{key}")

  defp optional_source(source, key, expected) do
    case value(source, key) do
      nil -> :ok
      actual -> equal(actual, expected, "source.#{key}", "state.source_#{key}")
    end
  end

  defp equal(value, value, _left, _right) when not is_nil(value), do: :ok
  defp equal(nil, _expected, left, _right), do: affinity_error(left, "missing_required_binding")
  defp equal(_actual, _expected, left, right), do: affinity_error(left, "conflicts_with_#{right}")

  defp affinity_error(path, reason),
    do:
      {:error,
       Error.incompatible!("Provider state affinity mismatch at #{path}", %{
         "field" => "affinity",
         "field_path" => path,
         "reason" => reason
       })}

  defp identity(map) do
    [:protocol, :profile, :endpoint, :account, :workspace, :model]
    |> Enum.reduce(%{}, fn key, identity ->
      case value(map, key) do
        nil -> identity
        item -> Map.put(identity, key, item)
      end
    end)
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
