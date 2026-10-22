defmodule Backplane.AgentRuntime.Codex.CollaborationBinding do
  @moduledoc false

  alias Backplane.AgentRuntime.Error

  @actions [:spawn, :message, :followup, :list, :wait, :interrupt]
  @descriptor_fields ~w(tool_name tool_revision schema backend safety codex_input_kind codex_format codex_output_schema)a

  def actions, do: @actions

  def new(manager_id, action, descriptor) do
    binding = %{manager_id: manager_id, action: action}
    Map.put(binding, :fingerprint, fingerprint(descriptor, binding))
  end

  def authorize(authority, descriptor) do
    case Map.get(descriptor, :collaboration_binding) do
      nil ->
        grants = Map.get(authority, :tool_bindings, %{})

        name = Map.get(descriptor, :tool_name, Map.get(descriptor, "tool_name"))

        if is_map(grants) and Map.has_key?(grants, name),
          do: forbidden(),
          else: :ok

      %{manager_id: manager, action: action, fingerprint: digest} = binding
      when is_binary(manager) and manager != "" and action in @actions and is_binary(digest) ->
        grants = Map.get(authority, :tool_bindings, %{})

        if is_map(grants) and grants[descriptor.tool_name] == digest and
             fingerprint(descriptor, binding) == digest,
           do: :ok,
           else: forbidden()

      _ ->
        forbidden()
    end
  end

  defp fingerprint(descriptor, binding) do
    value = {binding.manager_id, binding.action, Map.take(descriptor, @descriptor_fields)}

    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp forbidden,
    do: {:error, Error.new(:forbidden, "collaboration binding is not authorized")}
end
