defmodule Backplane.AgentRuntime.ToolCatalog do
  alias Backplane.AgentRuntime.{Error, InputSchema, Policy, ToolRegistry}

  @moduledoc """
  Validates complete, host-authored tool catalog revisions for a Conversation.

  Catalog revisions are independent of descriptor revisions. Registry backends,
  authority, and backend contexts remain ephemeral; provider definitions use the
  canonical `%{name:, description:, parameters:}` shape.
  """

  @type provider_tool :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @spec initial(keyword()) :: map()
  def initial(opts) do
    registry = Keyword.get(opts, :registry, %ToolRegistry{})

    %{
      revision: Keyword.get(opts, :catalog_revision, 1),
      registry: registry,
      authority: Keyword.get(opts, :authority, %{}),
      tools: Keyword.get_lazy(opts, :tools, fn -> definitions(registry) end),
      publication_id: nil
    }
  end

  @spec fence(term(), map()) :: :ok | {:error, Error.t()}
  def fence(update, run) when is_map(update) and is_map(run) do
    with {:ok, run_id} <- required_binary(update, :run_id, "run id"),
         {:ok, incarnation} <- required_positive_integer(update, :incarnation, "incarnation") do
      cond do
        run_id != Map.get(run, :run_id) ->
          conflict("catalog publication belongs to another run")

        incarnation != Map.get(run, :incarnation) ->
          conflict("catalog publication belongs to another incarnation")

        true ->
          :ok
      end
    end
  end

  def fence(_update, _run), do: validation("catalog publication must be a map")

  @spec validate(term(), pos_integer(), map()) :: {:ok, map()} | {:error, Error.t()}
  def validate(update, current_revision, run)
      when is_map(update) and is_integer(current_revision) and is_map(run) do
    with :ok <- fence(update, run),
         {:ok, publication_id} <- required_binary(update, :publication_id, "publication id"),
         {:ok, expected_revision} <-
           required_positive_integer(update, :expected_revision, "expected catalog revision"),
         :ok <- expected_revision(expected_revision, current_revision),
         {:ok, catalog} <- required_map(update, :catalog, "catalog"),
         {:ok, revision} <- required_positive_integer(catalog, :revision, "catalog revision"),
         :ok <- next_revision(revision, expected_revision),
         {:ok, registry} <- required_registry(catalog),
         {:ok, authority} <- required_map(catalog, :authority, "catalog authority"),
         {:ok, tools} <- provider_tools(catalog),
         :ok <- validate_bundle(registry, authority, tools, Map.fetch!(run, :run_id)) do
      {:ok,
       %{
         revision: revision,
         registry: registry,
         authority: authority,
         tools: tools,
         publication_id: publication_id
       }}
    end
  end

  def validate(_update, _current_revision, _run),
    do: validation("catalog publication is malformed")

  @spec receipt(map(), :staged | :published) :: map()
  def receipt(catalog, status) do
    %{
      publication_id: catalog.publication_id,
      catalog_revision: catalog.revision,
      status: status
    }
  end

  defp definitions(%ToolRegistry{tools: tools}) when is_map(tools) do
    tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, descriptor} ->
      %{
        name: name,
        description: Map.get(descriptor, :description, ""),
        parameters: Map.get(descriptor, :schema)
      }
    end)
  end

  defp definitions(_registry), do: []

  defp validate_bundle(registry, authority, tools, run_id) do
    descriptors = registry.tools

    if is_map(descriptors) do
      tool_names = Enum.map(tools, & &1.name)
      registry_names = Map.keys(descriptors)

      with :ok <- exact_names(tool_names, registry_names),
           :ok <- exact_grants(Map.get(authority, :grants), registry_names),
           :ok <- authority_run(authority, run_id) do
        Enum.reduce_while(tools, :ok, fn tool, :ok ->
          descriptor = Map.fetch!(descriptors, tool.name)

          case validate_tool(tool, descriptor, authority, run_id) do
            :ok -> {:cont, :ok}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
        end)
      end
    else
      validation("catalog registry tools must be a map")
    end
  end

  defp validate_tool(tool, descriptor, authority, run_id) when is_map(descriptor) do
    with :ok <- descriptor_metadata(descriptor),
         :ok <- exact_schema(tool, descriptor),
         :ok <- InputSchema.validate_schema(Map.get(descriptor, :schema)),
         :ok <- available_backend(descriptor),
         {:ok, _} <-
           Policy.authorize_tool(authority, descriptor, %{
             run_id: run_id,
             tool_name: tool.name
           }) do
      :ok
    end
  end

  defp validate_tool(_tool, _descriptor, _authority, _run_id),
    do: validation("registered tool descriptor must be a map")

  defp descriptor_metadata(descriptor) do
    safety = Map.get(descriptor, :safety)
    context = Map.get(descriptor, :backend_context, %{})

    required_safety = [:read_only, :retry_safe, :parallel_safe]

    if is_map(safety) and is_map(context) and
         Enum.all?(required_safety, &is_boolean(Map.get(safety, &1))) and
         (not Map.has_key?(safety, :requires_approval) or
            is_boolean(Map.get(safety, :requires_approval))) do
      :ok
    else
      validation("registered tool descriptor metadata is malformed")
    end
  end

  defp exact_names(tool_names, registry_names) do
    if length(tool_names) == length(Enum.uniq(tool_names)) and
         MapSet.new(tool_names) == MapSet.new(registry_names),
       do: :ok,
       else: validation("provider tools must exactly match the registry")
  end

  defp exact_grants(grants, registry_names) when is_list(grants) do
    if length(grants) == length(Enum.uniq(grants)) and
         MapSet.new(grants) == MapSet.new(registry_names),
       do: :ok,
       else: forbidden("catalog authority must exactly match the registry")
  end

  defp exact_grants(_grants, _registry_names),
    do: validation("catalog authority grants must be a list")

  defp authority_run(authority, run_id) do
    if Map.get(authority, :run_id) == run_id,
      do: :ok,
      else: forbidden("catalog authority belongs to another run")
  end

  defp exact_schema(%{parameters: schema}, descriptor) do
    if schema == Map.get(descriptor, :schema),
      do: :ok,
      else: conflict("provider tool schema differs from its registered descriptor")
  end

  defp available_backend(%{backend: backend}) when is_atom(backend) do
    if Code.ensure_loaded?(backend) and function_exported?(backend, :execute, 1),
      do: :ok,
      else: unsupported("registered tool backend is unavailable")
  end

  defp available_backend(_descriptor),
    do: unsupported("registered tool backend is unavailable")

  defp provider_tools(catalog) do
    case field(catalog, :tools) do
      tools when is_list(tools) ->
        Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
          case provider_tool(tool) do
            {:ok, tool} -> {:cont, {:ok, acc ++ [tool]}}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
        end)

      _ ->
        validation("catalog tools must be a list")
    end
  end

  defp provider_tool(tool) when is_map(tool) do
    with {:ok, name} <- required_binary(tool, :name, "provider tool name"),
         {:ok, description} <- required_string(tool, :description, "provider tool description"),
         {:ok, parameters} <- required_map(tool, :parameters, "provider tool parameters") do
      {:ok, %{name: name, description: description, parameters: parameters}}
    end
  end

  defp provider_tool(_tool), do: validation("provider tool definition must be a map")

  defp required_registry(catalog) do
    case field(catalog, :registry) do
      %ToolRegistry{} = registry -> {:ok, registry}
      _ -> validation("catalog registry is required")
    end
  end

  defp required_map(map, key, label) do
    case field(map, key) do
      value when is_map(value) -> {:ok, value}
      _ -> validation("#{label} is required")
    end
  end

  defp required_binary(map, key, label) do
    case field(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> validation("#{label} is required")
    end
  end

  defp required_string(map, key, label) do
    case field(map, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> validation("#{label} is required")
    end
  end

  defp required_positive_integer(map, key, label) do
    case field(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> validation("#{label} must be a positive integer")
    end
  end

  defp expected_revision(expected, current) do
    if expected == current,
      do: :ok,
      else: conflict("catalog revision is stale")
  end

  defp next_revision(revision, expected) do
    if revision == expected + 1,
      do: :ok,
      else: validation("catalog revision must advance by one")
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp validation(message), do: {:error, Error.new(:validation, message)}
  defp forbidden(message), do: {:error, Error.new(:forbidden, message)}
  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}
  defp unsupported(message), do: {:error, Error.new(:unsupported_capability, message)}
end
