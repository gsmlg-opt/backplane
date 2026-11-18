defmodule Backplane.AgentRuntime.InputSchema do
  alias Backplane.AgentRuntime.Error
  alias Formata.Schema

  @moduledoc """
  JSON Schema Draft 2020-12 boundary for MCP tool arguments.

  `Formata` owns schema semantics and offline schema preflight. This module keeps the runtime contract
  deliberately small: MCP tool roots are objects, host-authored atom keys are
  normalized without creating atoms, and external references are loaded only
  through an explicitly supplied registry or loader.
  """

  @draft2020_12 "https://json-schema.org/draft/2020-12/schema"
  @max_schema_bytes 1_048_576
  @max_schema_depth 128
  @max_schema_nodes 100_000
  @max_reference_count 10_000
  @max_input_depth 128
  @max_input_nodes 100_000

  @type options :: [
          {:schema_registry, map()},
          {:schema_loader, (String.t() -> {:ok, map() | boolean()} | {:error, term()})},
          {:loader, (String.t() -> {:ok, map() | boolean()} | {:error, term()})},
          {:format_assertion, boolean()},
          {:content_assertion, boolean()}
        ]

  @spec validate_schema(term()) :: :ok | {:error, Error.t()}
  def validate_schema(schema), do: validate_schema(schema, [])

  @spec validate_schema(term(), options()) :: :ok | {:error, Error.t()}
  def validate_schema(schema, opts) when is_list(opts) do
    with {:ok, normalized} <- normalize_schema(schema),
         :ok <- enforce_limits(normalized, :schema),
         :ok <- validate_dialect(normalized),
         :ok <- validate_root_object(normalized),
         {:ok, _compiled} <- compile(normalized, opts) do
      :ok
    end
  end

  def validate_schema(_schema, _opts), do: validation("schema options must be a list")

  @spec validate(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def validate(schema, input), do: validate(schema, input, [])

  @spec validate(term(), term(), options()) :: {:ok, map()} | {:error, Error.t()}
  def validate(schema, input, opts) when is_list(opts) do
    with :ok <- ensure_input_map(input),
         :ok <- enforce_limits(input, :input),
         {:ok, normalized} <- normalize_schema(schema),
         :ok <- enforce_limits(normalized, :schema),
         :ok <- validate_dialect(normalized),
         :ok <- validate_root_object(normalized),
         {:ok, compiled} <- compile(normalized, opts),
         {:ok, _} <- validate_compiled(compiled, input) do
      {:ok, input}
    end
  end

  def validate(_schema, _input, _opts), do: validation("schema options must be a list")

  defp ensure_input_map(input) when is_map(input), do: :ok
  defp ensure_input_map(_input), do: validation("tool schema and arguments must be maps")

  defp validate_root_object(schema) do
    case Map.get(schema, "type") do
      nil ->
        :ok

      "object" ->
        :ok

      ["object"] ->
        :ok

      type ->
        {:error,
         Error.new(:unsupported_capability, "only object tool schemas are supported",
           details: %{type: type}
         )}
    end
  end

  defp validate_dialect(schema) do
    case find_unsupported_dialect(schema) do
      nil ->
        :ok

      value ->
        {:error,
         Error.new(:unsupported_capability, "JSON Schema dialect is unsupported",
           details: %{schema: value, supported: @draft2020_12}
         )}
    end
  end

  defp find_unsupported_dialect(value) when is_map(value) do
    case Map.get(value, "$schema") do
      nil -> Enum.find_value(Map.values(value), &find_unsupported_dialect/1)
      @draft2020_12 -> Enum.find_value(Map.values(value), &find_unsupported_dialect/1)
      @draft2020_12 <> "#" -> Enum.find_value(Map.values(value), &find_unsupported_dialect/1)
      value -> value
    end
  end

  defp find_unsupported_dialect(value) when is_list(value),
    do: Enum.find_value(value, &find_unsupported_dialect/1)

  defp find_unsupported_dialect(_value), do: nil

  defp compile(schema, opts) do
    with {:ok, loader} <- explicit_loader(opts) do
      compile_opts =
        [
          dialect: :draft2020_12,
          loader: normalized_loader(loader),
          format_assertion: Keyword.get(opts, :format_assertion, false),
          content_assertion: Keyword.get(opts, :content_assertion, false),
          max_bytes: @max_schema_bytes,
          max_depth: @max_schema_depth,
          max_nodes: @max_schema_nodes,
          max_refs: @max_reference_count,
          max_resources: @max_reference_count + 1
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      try do
        case Formata.Schema.JSONSchema.preflight(schema, compile_opts) do
          {:ok, %Schema{} = compiled} -> {:ok, compiled}
          {:error, errors} -> {:error, compile_error(errors)}
        end
      rescue
        exception ->
          {:error,
           Error.new(:execution_failure, "JSON Schema compilation failed",
             details: %{exception: inspect(exception)},
             cause: exception
           )}
      catch
        kind, reason ->
          {:error,
           Error.new(:execution_failure, "JSON Schema compilation failed",
             details: %{kind: kind, reason: inspect(reason)},
             cause: reason
           )}
      end
    end
  end

  defp validate_compiled(compiled, input) do
    try do
      case Formata.validate(input, compiled) do
        :ok ->
          {:ok, input}

        {:error, errors} ->
          {:error, validation_errors(errors)}
      end
    rescue
      exception ->
        {:error,
         Error.new(:execution_failure, "JSON Schema validation failed",
           details: %{exception: inspect(exception)},
           cause: exception
         )}
    catch
      kind, reason ->
        {:error,
         Error.new(:execution_failure, "JSON Schema validation failed",
           details: %{kind: kind, reason: inspect(reason)},
           cause: reason
         )}
    end
  end

  defp normalize_schema(schema) when is_map(schema), do: normalize_value(schema, [])
  defp normalize_schema(_schema), do: validation("tool schema must be a map")

  defp normalize_value(value, path) when is_map(value) do
    if is_struct(value) do
      validation("schema values must be JSON values", %{path: path})
    else
      Enum.reduce_while(value, {:ok, %{}}, fn {key, child}, {:ok, acc} ->
        with {:ok, normalized_key} <- normalize_key(key),
             {:ok, normalized_child} <- normalize_value(child, [normalized_key | path]) do
          if Map.has_key?(acc, normalized_key) do
            {:halt,
             validation("schema contains duplicate keys after normalization", %{path: path})}
          else
            {:cont, {:ok, Map.put(acc, normalized_key, normalized_child)}}
          end
        else
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, canonicalize_legacy_keys(normalized)}
        error -> error
      end
    end
  end

  defp normalize_value(value, path) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn child, {:ok, acc} ->
      case normalize_value(child, path) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_value(value, _path)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize_value(value, ["type" | _path]) when is_atom(value),
    do: {:ok, Atom.to_string(value)}

  defp normalize_value(_value, path),
    do: validation("schema values must be JSON values", %{path: path})

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp normalize_key(key),
    do: validation("schema object keys must be strings or atoms", %{key: key})

  defp canonicalize_legacy_keys(schema) do
    case Map.pop(schema, "additional_properties") do
      {nil, schema} -> schema
      {value, schema} -> Map.put_new(schema, "additionalProperties", value)
    end
  end

  defp explicit_loader(opts) do
    registry = Keyword.get(opts, :schema_registry)
    loader = Keyword.get(opts, :schema_loader) || Keyword.get(opts, :loader)

    cond do
      is_map(registry) and is_nil(loader) ->
        {:ok,
         fn uri ->
           case Map.fetch(registry, uri) do
             {:ok, schema} -> {:ok, schema}
             :error -> {:error, :schema_not_found}
           end
         end}

      is_map(registry) and is_function(loader, 1) ->
        validation("provide either schema_registry or schema_loader, not both")

      is_nil(registry) and is_nil(loader) ->
        {:ok, nil}

      is_nil(registry) and is_function(loader, 1) ->
        {:ok, loader}

      true ->
        validation("schema_registry must be a map and schema_loader must be a function")
    end
  end

  defp normalized_loader(nil), do: nil

  defp normalized_loader(loader) do
    fn uri ->
      case loader.(uri) do
        {:ok, loaded} ->
          case prepare_loaded_reference(loaded) do
            {:ok, normalized} -> {:ok, normalized}
            {:error, %Error{} = error} -> {:error, {:invalid_schema, error}}
          end

        other ->
          other
      end
    end
  end

  defp prepare_loaded_reference(%{document: document} = loaded) do
    with {:ok, normalized} <- normalize_loaded_document(document),
         :ok <- enforce_limits(normalized, :schema) do
      {:ok, Map.put(loaded, :document, normalized)}
    end
  end

  defp prepare_loaded_reference(loaded) do
    with {:ok, normalized} <- normalize_loaded_document(loaded),
         :ok <- enforce_limits(normalized, :schema) do
      {:ok, normalized}
    end
  end

  defp normalize_loaded_document(document) when is_boolean(document), do: {:ok, document}
  defp normalize_loaded_document(document), do: normalize_schema(document)

  defp enforce_limits(value, :schema) do
    with :ok <- enforce_size(value),
         {:ok, _state} <- enforce_shape_limits(value, 0, %{nodes: 0}, :schema) do
      :ok
    end
  end

  defp enforce_limits(value, :input),
    do: enforce_shape_limits(value, 0, %{nodes: 0}, :input) |> normalize_limit_result()

  defp normalize_limit_result({:ok, _state}), do: :ok
  defp normalize_limit_result({:error, %Error{} = error}), do: {:error, error}

  defp enforce_size(value) do
    if :erlang.external_size(value) <= @max_schema_bytes,
      do: :ok,
      else: {:error, limit_error(:schema_bytes, @max_schema_bytes)}
  end

  defp enforce_shape_limits(_value, depth, _state, :input) when depth > @max_input_depth,
    do: {:error, limit_error(:input_depth, @max_input_depth)}

  defp enforce_shape_limits(_value, depth, _state, :schema) when depth > @max_schema_depth,
    do: {:error, limit_error(:schema_depth, @max_schema_depth)}

  defp enforce_shape_limits(value, depth, state, kind) when is_map(value) or is_list(value) do
    nodes = state.nodes + 1
    max_nodes = if kind == :schema, do: @max_schema_nodes, else: @max_input_nodes

    if nodes > max_nodes do
      limit = if kind == :schema, do: :schema_nodes, else: :input_nodes
      {:error, limit_error(limit, max_nodes)}
    else
      children = if is_map(value), do: Map.values(value), else: value

      Enum.reduce_while(children, {:ok, %{state | nodes: nodes}}, fn child, {:ok, acc} ->
        case enforce_shape_limits(child, depth + 1, acc, kind) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp enforce_shape_limits(_value, _depth, state, _kind), do: {:ok, state}

  defp compile_error([error | _]), do: compile_error(error)

  defp compile_error(%Formata.Error{code: code} = error)
       when code in [:unsupported_vocabulary, :unsupported_keyword] do
    Error.new(:unsupported_capability, "JSON Schema capability is unsupported",
      details: %{error: Exception.message(error)}
    )
  end

  defp compile_error(%Formata.Error{code: :limit_exceeded, details: %{limit: limit}}) do
    {name, maximum} =
      case limit do
        :max_depth -> {:schema_depth, @max_schema_depth}
        :max_nodes -> {:schema_nodes, @max_schema_nodes}
        :max_bytes -> {:schema_bytes, @max_schema_bytes}
        :max_refs -> {:references, @max_reference_count}
        :max_resources -> {:resources, @max_reference_count + 1}
      end

    limit_error(name, maximum)
  end

  defp compile_error(%Formata.Error{
         code: :unresolved_ref,
         details: %{reference: reference, reason: {:error, :missing_loader}}
       }) do
    Error.new(:validation, "external schema reference requires an explicit loader",
      details: %{reference: reference}
    )
  end

  defp compile_error(%Formata.Error{
         code: :unresolved_ref,
         details: %{reference: reference, reason: reason}
       }) do
    Error.new(:execution_failure, "external schema reference could not be loaded",
      details: %{reference: reference, reason: inspect(reason)}
    )
  end

  defp compile_error(%Formata.Error{code: :unresolved_ref, details: %{reference: reference}}) do
    Error.new(:validation, "schema reference could not be resolved",
      details: %{reference: reference}
    )
  end

  defp compile_error(error),
    do: Error.new(:validation, "tool schema is invalid", details: %{error: inspect(error)})

  defp validation_errors([]),
    do: Error.new(:execution_failure, "JSON Schema validator returned no errors")

  defp validation_errors([%Formata.Error{} = error | _] = errors) do
    class =
      case {error.kind, error.code} do
        {:schema, _} -> :execution_failure
        {:unsupported, :non_json_value} -> :validation
        {:unsupported, _} -> :unsupported_capability
        _ -> :validation
      end

    base_details = %{
      errors: Enum.map(errors, &format_error/1),
      path: error_path(error.path)
    }

    details = add_constraint_details(base_details, errors)

    Error.new(class, Exception.message(error), details: details)
  end

  defp error_path([]), do: "$arguments"

  defp error_path(path) do
    Enum.reduce(path, "$arguments", fn
      segment, acc when is_integer(segment) -> acc <> "[" <> Integer.to_string(segment) <> "]"
      segment, "$arguments" -> "$arguments." <> to_string(segment)
      segment, acc -> acc <> "." <> to_string(segment)
    end)
  end

  defp add_constraint_details(details, errors) do
    Enum.reduce(errors, details, fn error, acc ->
      case error.details do
        %{contrast: contrast}
        when error.code in [:minimum, :maximum, :exclusiveMinimum, :exclusiveMaximum] ->
          Map.put_new(acc, error.code, contrast)

        %{contrast: contrast} when error.code == :type ->
          Map.put_new(acc, :type, contrast)

        %{contrast: contrast} when error.code == :required and is_list(contrast) ->
          Map.put_new(acc, :property, List.first(contrast))

        _ ->
          acc
      end
    end)
  end

  defp format_error(error) do
    %{
      path: Map.get(error, :path, []),
      rule: error.code,
      message: Exception.message(error)
    }
  end

  defp limit_error(limit, maximum),
    do:
      Error.new(:execution_failure, "JSON Schema resource limit exceeded",
        details: %{limit: limit, maximum: maximum}
      )

  defp validation(message, details \\ %{}),
    do: {:error, Error.new(:validation, message, details: details)}
end
