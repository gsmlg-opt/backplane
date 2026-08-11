defmodule Backplane.McpProtocol.Client.Catalog do
  @moduledoc """
  Compiles a tool list into an immutable snapshot for parameter-header projection.

  A tool is retained only when every `x-mcp-header` annotation in its input
  schema is attached to a primitive property reachable through `properties`
  entries alone.
  """

  require Logger

  @header_token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @primitive_types ~w(string integer boolean)

  defstruct tools: [], projections: %{}, next_cursor: nil

  @type path :: [String.t()]
  @type projection :: {path(), String.t()}
  @type t :: %__MODULE__{
          tools: [map()],
          projections: %{optional(String.t()) => [projection()]},
          next_cursor: String.t() | nil
        }

  @doc "Returns an empty catalog snapshot."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Compiles raw tools into one immutable catalog snapshot."
  @spec compile([map()]) :: t()
  def compile(tools) when is_list(tools) do
    {compiled_tools, projections} =
      Enum.reduce(tools, {[], %{}}, fn tool, {compiled_tools, projections} ->
        case compile_tool(tool) do
          {:ok, name, tool_projections} ->
            {[tool | compiled_tools], Map.put(projections, name, tool_projections)}

          {:error, name, reason} ->
            Logger.warning(
              "Excluded Streamable HTTP tool name=#{inspect(name, limit: 5, printable_limit: 128)} reason=#{reason}"
            )

            {compiled_tools, projections}
        end
      end)

    %__MODULE__{tools: Enum.reverse(compiled_tools), projections: projections}
  end

  @doc "Returns the raw tools retained in a compiled snapshot."
  @spec tools(t()) :: [map()]
  def tools(%__MODULE__{tools: tools}), do: tools

  @doc "Projects declared argument values into `Mcp-Param-*` headers."
  @spec parameter_headers(t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def parameter_headers(%__MODULE__{projections: projections}, tool_name, arguments)
      when is_binary(tool_name) and is_map(arguments) do
    with {:ok, arguments} <- normalize_arguments(arguments) do
      projections
      |> Map.get(tool_name, [])
      |> Enum.reduce({:ok, %{}}, fn {path, annotation}, {:ok, headers} ->
        case fetch_path(arguments, path) do
          :missing -> {:ok, headers}
          {:ok, nil} -> {:ok, headers}
          {:ok, value} -> {:ok, Map.put(headers, "Mcp-Param-" <> annotation, value)}
        end
      end)
    end
  end

  def parameter_headers(%__MODULE__{}, _tool_name, _arguments), do: {:error, :invalid_arguments}

  @doc "Compiles and atomically replaces a snapshot in the calling process."
  @spec replace(term(), [map()]) :: t()
  def replace(key, tools) when is_list(tools) do
    catalog = compile(tools)
    Process.put(process_key(key), catalog)
    catalog
  end

  @doc "Stores one filtered page and merges it only when its request cursor continues the active chain."
  @spec put_page(term(), String.t() | nil, String.t() | nil, [map()]) :: {[map()], t()}
  def put_page(key, request_cursor, next_cursor, tools) when is_list(tools) do
    page = compile(tools)
    current = current(key)

    catalog =
      if continuation?(current, request_cursor) do
        merge_page(current, page, tools)
      else
        page
      end

    catalog = %{catalog | next_cursor: next_cursor}
    Process.put(process_key(key), catalog)

    {tools(page), catalog}
  end

  @doc "Returns the calling process's current snapshot for `key`."
  @spec current(term()) :: t()
  def current(key), do: Process.get(process_key(key), empty())

  @doc "Removes the calling process's snapshot for `key`."
  @spec cleanup(term()) :: :ok
  def cleanup(key) do
    Process.delete(process_key(key))
    :ok
  end

  defp continuation?(%__MODULE__{next_cursor: expected}, request_cursor) do
    is_binary(request_cursor) and request_cursor == expected
  end

  defp merge_page(current, page, raw_tools) do
    redefined_names =
      Enum.reduce(raw_tools, MapSet.new(), fn
        %{"name" => name}, names when is_binary(name) -> MapSet.put(names, name)
        _invalid_tool, names -> names
      end)

    retained_tools =
      Enum.reject(current.tools, fn tool -> MapSet.member?(redefined_names, tool["name"]) end)

    retained_projections = Map.drop(current.projections, MapSet.to_list(redefined_names))

    %__MODULE__{
      tools: retained_tools ++ page.tools,
      projections: Map.merge(retained_projections, page.projections)
    }
  end

  defp compile_tool(%{"name" => name, "inputSchema" => schema})
       when is_binary(name) and is_map(schema) do
    case scan_schema(schema, [], MapSet.new(), []) do
      {:ok, _seen, projections} -> {:ok, name, Enum.reverse(projections)}
      {:error, reason} -> {:error, name, reason}
    end
  end

  defp compile_tool(%{} = tool),
    do: {:error, Map.get(tool, "name", "<missing>"), :invalid_tool_schema}

  defp compile_tool(_tool), do: {:error, "<invalid>", :invalid_tool_schema}

  defp scan_schema(schema, path, seen, projections) when is_map(schema) do
    with {:ok, seen, projections} <- compile_annotation(schema, path, seen, projections) do
      Enum.reduce_while(schema, {:ok, seen, projections}, fn
        {"properties", properties}, {:ok, seen, projections} when is_map(properties) ->
          continue(scan_properties(properties, path, seen, projections))

        {"properties", value}, {:ok, seen, projections} ->
          continue(scan_unreachable(value, seen, projections))

        {"x-mcp-header", _annotation}, result ->
          {:cont, result}

        {_keyword, value}, {:ok, seen, projections} ->
          continue(scan_unreachable(value, seen, projections))
      end)
    end
  end

  defp scan_properties(properties, path, seen, projections) do
    Enum.reduce_while(properties, {:ok, seen, projections}, fn
      {property, schema}, {:ok, seen, projections}
      when is_binary(property) and is_map(schema) ->
        case scan_schema(schema, path ++ [property], seen, projections) do
          {:ok, seen, projections} -> {:cont, {:ok, seen, projections}}
          {:error, _reason} = error -> {:halt, error}
        end

      {_property, schema}, {:ok, seen, projections} ->
        continue(scan_unreachable(schema, seen, projections))
    end)
  end

  defp scan_unreachable(value, seen, projections) when is_map(value) do
    if Map.has_key?(value, "x-mcp-header") do
      {:error, :unreachable_header_annotation}
    else
      Enum.reduce_while(value, {:ok, seen, projections}, fn {_key, nested},
                                                            {:ok, seen, projections} ->
        continue(scan_unreachable(nested, seen, projections))
      end)
    end
  end

  defp scan_unreachable(value, seen, projections) when is_list(value) do
    Enum.reduce_while(value, {:ok, seen, projections}, fn nested, {:ok, seen, projections} ->
      continue(scan_unreachable(nested, seen, projections))
    end)
  end

  defp scan_unreachable(_value, seen, projections), do: {:ok, seen, projections}

  defp continue({:ok, _seen, _projections} = result), do: {:cont, result}
  defp continue({:error, _reason} = error), do: {:halt, error}

  defp compile_annotation(schema, path, seen, projections) do
    case Map.fetch(schema, "x-mcp-header") do
      :error ->
        {:ok, seen, projections}

      {:ok, annotation} ->
        normalized = if is_binary(annotation), do: String.downcase(annotation)

        cond do
          path == [] ->
            {:error, :root_header_annotation}

          not valid_annotation?(annotation) ->
            {:error, :invalid_header_annotation}

          schema["type"] not in @primitive_types ->
            {:error, :non_primitive_header_annotation}

          MapSet.member?(seen, normalized) ->
            {:error, :duplicate_header_annotation}

          true ->
            {:ok, MapSet.put(seen, normalized), [{path, annotation} | projections]}
        end
    end
  end

  defp valid_annotation?(annotation) when is_binary(annotation),
    do: Regex.match?(@header_token, annotation)

  defp valid_annotation?(_annotation), do: false

  defp fetch_path(arguments, [key]) do
    case Map.fetch(arguments, key) do
      {:ok, value} -> {:ok, value}
      :error -> :missing
    end
  end

  defp fetch_path(arguments, [key | rest]) do
    case Map.fetch(arguments, key) do
      {:ok, nested} when is_map(nested) -> fetch_path(nested, rest)
      _missing_or_non_object -> :missing
    end
  end

  defp normalize_arguments(arguments) do
    case arguments |> JSON.encode!() |> JSON.decode() do
      {:ok, normalized} when is_map(normalized) -> {:ok, normalized}
      _invalid -> {:error, :invalid_arguments}
    end
  rescue
    _error -> {:error, :invalid_arguments}
  end

  defp process_key(key), do: {__MODULE__, key}
end
