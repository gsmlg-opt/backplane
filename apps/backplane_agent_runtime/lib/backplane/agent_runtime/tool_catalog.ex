defmodule Backplane.AgentRuntime.ToolCatalog do
  alias Backplane.AgentRuntime.{Error, InputSchema, Policy, ToolRegistry}

  @type admission :: %{
          registry: ToolRegistry.t(),
          tools: [provider_tool()],
          authority: map(),
          accepted: [String.t()],
          rejected: [map()]
        }

  @doc """
  Admits a complete tool batch without mutating a registry or dispatching a backend.

  Admission is strict by default. `mode: :quarantine` is the only mode that
  turns a direct `InputSchema.validate_schema/1` `:unsupported_capability`
  result into a rejected diagnostic. Every other error remains fatal.
  """
  @spec admit_batch(term(), keyword()) :: {:ok, admission()} | {:error, Error.t()}
  def admit_batch(batch, opts \\ [])

  def admit_batch(batch, opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, mode} <- admission_mode(opts),
         {:ok, %{descriptors: descriptors, tools: supplied_tools, authority: authority}} <-
           admission_input(batch, opts),
         :ok <- reject_duplicate_names(descriptors),
         {:ok, names} <- descriptor_names(descriptors),
         :ok <- validate_authority(authority, names),
         {:ok, entries} <- validate_descriptors(descriptors, authority, mode),
         {:ok, accepted, rejected} <- split_entries(entries),
         :ok <- validate_supplied_tools(supplied_tools, entries),
         {:ok, registry} <- registry_from_entries(accepted),
         {:ok, tools} <- provider_definitions(accepted, supplied_tools),
         {:ok, authority} <- narrowed_authority(authority, accepted) do
      {:ok,
       %{
         registry: registry,
         tools: tools,
         authority: authority,
         accepted: Enum.map(accepted, & &1.name),
         rejected: rejected
       }}
    end
  end

  def admit_batch(_batch, _opts),
    do: {:error, validation_error("admission options must be a list")}

  @spec admit_batch(ToolRegistry.t(), map(), keyword()) ::
          {:ok, admission()} | {:error, Error.t()}
  def admit_batch(%ToolRegistry{} = registry, authority, opts) when is_map(authority) do
    admit_batch(%{registry: registry, authority: authority}, opts)
  end

  defp admission_mode(opts) do
    case Keyword.get(opts, :mode, :strict) do
      mode when mode in [:strict, :quarantine] -> {:ok, mode}
      _ -> {:error, validation_error("admission mode must be :strict or :quarantine")}
    end
  end

  defp validate_options(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, validation_error("admission options must be a keyword list")}

      Enum.any?(opts, fn {key, _value} -> key not in [:mode, :authority, :tools] end) ->
        {:error, validation_error("unknown admission option")}

      true ->
        :ok
    end
  end

  defp admission_input(%ToolRegistry{tools: tools} = registry, opts) when is_map(tools) do
    admission_input(
      %{
        registry: registry,
        authority: Keyword.get(opts, :authority, %{}),
        tools: Keyword.get(opts, :tools)
      },
      opts
    )
  end

  defp admission_input(
         %{registry: %ToolRegistry{tools: tools}, authority: authority} = batch,
         _opts
       )
       when is_map(tools) and is_map(authority) do
    descriptors =
      tools
      |> Enum.sort_by(fn {name, _descriptor} -> name end)
      |> Enum.map(&elem(&1, 1))

    {:ok, %{descriptors: descriptors, tools: Map.get(batch, :tools), authority: authority}}
  end

  defp admission_input(descriptors, opts) when is_list(descriptors) do
    authority = Keyword.get(opts, :authority, %{})

    if is_map(authority),
      do:
        {:ok, %{descriptors: descriptors, tools: Keyword.get(opts, :tools), authority: authority}},
      else: {:error, validation_error("admission authority must be a map")}
  end

  defp admission_input(_batch, _opts),
    do: {:error, validation_error("admission batch is malformed")}

  defp reject_duplicate_names(descriptors) do
    names = Enum.map(descriptors, &candidate_name/1)

    if length(names) == length(Enum.uniq(names)),
      do: :ok,
      else: {:error, validation_error("admission batch contains duplicate tool names")}
  end

  defp descriptor_names(descriptors) do
    Enum.reduce_while(descriptors, {:ok, []}, fn descriptor, {:ok, acc} ->
      case descriptor_name(descriptor) do
        {:ok, name} -> {:cont, {:ok, [name | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp descriptor_name(descriptor) when is_map(descriptor) do
    case Map.get(descriptor, :tool_name) || Map.get(descriptor, "tool_name") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, validation_error("tool name is required")}
    end
  end

  defp descriptor_name(_), do: {:error, validation_error("tool descriptor must be a map")}

  defp validate_authority(authority, names) do
    grants = Map.get(authority, :grants, Map.get(authority, "grants"))

    if is_list(grants) and length(grants) == length(Enum.uniq(grants)) and
         MapSet.new(grants) == MapSet.new(names),
       do: :ok,
       else:
         {:error,
          Error.new(:forbidden, "admission authority must exactly match the candidate tools")}
  end

  defp validate_descriptors(descriptors, authority, mode) do
    Enum.reduce_while(descriptors, {:ok, []}, fn descriptor, {:ok, acc} ->
      case validate_admission_descriptor(descriptor, authority, mode) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_admission_descriptor(descriptor, authority, mode) when is_map(descriptor) do
    with {:ok, name} <- descriptor_name(descriptor),
         {:ok, revision} <- descriptor_revision(descriptor),
         :ok <- descriptor_metadata(descriptor),
         :ok <- available_backend(descriptor),
         {:ok, _} <-
           Policy.authorize_tool(authority_for_tool(authority, name), descriptor, %{
             tool_name: name,
             run_id: Map.get(authority, :run_id)
           }) do
      case InputSchema.validate_schema(Map.get(descriptor, :schema)) do
        :ok ->
          {:ok, %{name: name, revision: revision, descriptor: descriptor, status: :accepted}}

        {:error, %Error{class: :unsupported_capability} = error} when mode == :quarantine ->
          {:ok,
           %{
             name: name,
             revision: revision,
             descriptor: descriptor,
             status: :rejected,
             error: error
           }}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  defp validate_admission_descriptor(_descriptor, _authority, _mode),
    do: {:error, validation_error("tool descriptor must be a map")}

  defp descriptor_revision(descriptor) do
    case Map.get(descriptor, :tool_revision) || Map.get(descriptor, "tool_revision") do
      revision when is_integer(revision) and revision > 0 -> {:ok, revision}
      _ -> {:error, validation_error("tool revision is required")}
    end
  end

  defp authority_for_tool(authority, name) do
    revisions = Map.get(authority, :tool_revisions, Map.get(authority, "tool_revisions", %{}))

    if is_map(revisions) and is_integer(Map.get(revisions, name)),
      do: Map.put(authority, :tool_revision, Map.get(revisions, name)),
      else: authority
  end

  defp split_entries(entries) do
    {accepted, rejected} = Enum.split_with(entries, &(&1.status == :accepted))

    rejected =
      Enum.map(rejected, fn entry ->
        %{name: entry.name, descriptor_revision: entry.revision, error: entry.error}
      end)

    {:ok, Enum.reverse(accepted), Enum.reverse(rejected)}
  end

  defp validate_supplied_tools(nil, _accepted), do: :ok

  defp validate_supplied_tools(tools, accepted) when is_list(tools) do
    accepted_names = MapSet.new(Enum.map(accepted, & &1.name))
    supplied_names = Enum.map(tools, &candidate_name(&1, :name))

    cond do
      length(supplied_names) != length(Enum.uniq(supplied_names)) or
          MapSet.new(supplied_names) != accepted_names ->
        {:error, validation_error("provider tools must match the admitted registry")}

      Enum.any?(accepted, fn entry ->
        tool = Enum.find(tools, &(candidate_name(&1, :name) == entry.name))

        not is_map(tool) or
            Map.get(tool, :parameters, Map.get(tool, "parameters")) != entry.descriptor.schema
      end) ->
        {:error,
         Error.new(
           :resource_conflict,
           "provider tool schema differs from its registered descriptor"
         )}

      true ->
        :ok
    end
  end

  defp validate_supplied_tools(_, _),
    do: {:error, validation_error("provider tools must be a list")}

  defp registry_from_entries(entries) do
    Enum.reduce_while(entries, {:ok, %ToolRegistry{}}, fn entry, {:ok, registry} ->
      case ToolRegistry.register(registry, entry.descriptor) do
        {:ok, registry} -> {:cont, {:ok, registry}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp provider_definitions(entries, nil), do: {:ok, Enum.map(entries, &provider_definition/1)}

  defp provider_definitions(entries, supplied) do
    by_name =
      Map.new(supplied, fn tool -> {candidate_name(tool, :name), tool} end)

    {:ok,
     Enum.map(entries, fn entry ->
       Map.fetch!(by_name, entry.name) |> normalize_provider_definition(entry)
     end)}
  end

  defp normalize_provider_definition(tool, entry) do
    %{
      name: entry.name,
      description: Map.get(tool, :description, Map.get(tool, "description", "")),
      parameters: entry.descriptor.schema
    }
  end

  defp candidate_name(value), do: candidate_name(value, :tool_name)

  defp candidate_name(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp candidate_name(_value, _key), do: nil

  defp provider_definition(entry),
    do: %{
      name: entry.name,
      description: Map.get(entry.descriptor, :description, ""),
      parameters: entry.descriptor.schema
    }

  defp narrowed_authority(authority, accepted) do
    names = Enum.map(accepted, & &1.name)
    {:ok, Map.put(authority, :grants, names)}
  end

  defp validation_error(message), do: Error.new(:validation, message)

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
    with {:ok, update} <- admit_catalog_update(update),
         :ok <- fence(update, run),
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
         rejected: Map.get(catalog, :rejected, []),
         publication_id: publication_id
       }}
    end
  end

  def validate(_update, _current_revision, _run),
    do: validation("catalog publication is malformed")

  defp admit_catalog_update(update) do
    catalog = field(update, :catalog)

    mode =
      field(update, :schema_admission) ||
        if(is_map(catalog), do: field(catalog, :schema_admission), else: nil)

    cond do
      is_nil(mode) ->
        {:ok, update}

      mode not in [:strict, :quarantine] ->
        {:error, validation_error("admission mode must be :strict or :quarantine")}

      not is_map(catalog) ->
        {:ok, update}

      true ->
        case admit_batch(
               %{
                 registry: field(catalog, :registry),
                 authority: field(catalog, :authority),
                 tools: field(catalog, :tools)
               },
               mode: mode
             ) do
          {:ok, bundle} ->
            {:ok,
             put_in(
               update,
               [:catalog],
               catalog
               |> Map.put(:registry, bundle.registry)
               |> Map.put(:authority, bundle.authority)
               |> Map.put(:tools, bundle.tools)
               |> Map.put(:rejected, bundle.rejected)
             )}

          {:error, error} ->
            {:error, error}
        end
    end
  end

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
