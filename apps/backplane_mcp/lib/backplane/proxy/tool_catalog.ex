defmodule Backplane.Proxy.ToolCatalog do
  @moduledoc """
  Normalizes and bounds upstream MCP tool catalogs.

  Catalog replacement is atomic: callers receive either the complete ordered
  catalog or one sanitized error, never a partial page or partial normalization.
  """

  alias Backplane.McpProtocol.MCP.Response
  alias Backplane.Registry.Tool

  @max_pages 100

  @type error_reason ::
          :invalid_tool
          | :duplicate_tool_name
          | :invalid_catalog
          | :invalid_catalog_page
          | :catalog_request_failed
          | :invalid_cursor
          | :cursor_cycle
          | :too_many_pages

  @doc "Normalizes one raw upstream tool without discarding known MCP fields."
  @spec normalize(term(), String.t(), pid(), pos_integer()) ::
          {:ok, Tool.t()} | {:error, :invalid_tool}
  def normalize(%{"name" => name} = raw, prefix, upstream_pid, timeout) do
    with :ok <- validate_name(name),
         {:ok, title} <- optional_field(raw, "title", &is_binary/1),
         {:ok, description} <- defaulted_field(raw, "description", "", &is_binary/1),
         {:ok, input_schema} <- defaulted_field(raw, "inputSchema", %{}, &is_map/1),
         {:ok, output_schema} <- optional_field(raw, "outputSchema", &is_map/1),
         {:ok, annotations} <- optional_field(raw, "annotations", &valid_tool_annotations?/1),
         {:ok, icon} <- optional_field(raw, "icon", &is_map/1),
         {:ok, icons} <- optional_field(raw, "icons", &valid_icons?/1),
         {:ok, meta} <- optional_field(raw, "_meta", &is_map/1),
         {:ok, execution} <- optional_field(raw, "execution", &is_map/1) do
      {:ok,
       %Tool{
         name: name,
         title: title,
         description: description,
         input_schema: input_schema,
         output_schema: output_schema,
         annotations: annotations,
         icon: icon,
         icons: icons,
         meta: meta,
         execution: execution,
         origin: {:upstream, prefix},
         upstream_pid: upstream_pid,
         original_name: name,
         timeout: timeout
       }}
    else
      :error -> {:error, :invalid_tool}
    end
  end

  def normalize(_raw, _prefix, _upstream_pid, _timeout), do: {:error, :invalid_tool}

  @doc "Normalizes an ordered catalog atomically."
  @spec normalize_all(term(), String.t(), pid(), pos_integer()) ::
          {:ok, [Tool.t()]}
          | {:error, :invalid_catalog | :invalid_tool | :duplicate_tool_name}
  def normalize_all(raw_tools, prefix, upstream_pid, timeout) when is_list(raw_tools) do
    raw_tools
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn raw, {:ok, tools, names} ->
      case normalize(raw, prefix, upstream_pid, timeout) do
        {:ok, %Tool{name: name} = tool} ->
          if MapSet.member?(names, name) do
            {:halt, {:error, :duplicate_tool_name}}
          else
            {:cont, {:ok, [tool | tools], MapSet.put(names, name)}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tools, _names} -> {:ok, Enum.reverse(tools)}
      {:error, _reason} = error -> error
    end
  end

  def normalize_all(_raw_tools, _prefix, _upstream_pid, _timeout),
    do: {:error, :invalid_catalog}

  @doc "Fetches at most 100 cursor-linked tool pages atomically."
  @spec fetch_all((String.t() | nil -> term())) ::
          {:ok, [map()]} | {:error, error_reason()}
  def fetch_all(page_fun) when is_function(page_fun, 1) do
    fetch_pages(page_fun, nil, MapSet.new(), MapSet.new(), [], 0)
  end

  def fetch_all(_page_fun), do: {:error, :invalid_catalog_page}

  defp fetch_pages(_page_fun, _cursor, _seen_cursors, _seen_names, _page_chunks, pages)
       when pages >= @max_pages,
       do: {:error, :too_many_pages}

  defp fetch_pages(page_fun, cursor, seen_cursors, seen_names, page_chunks, pages) do
    with {:ok, page_tools, next_cursor} <- fetch_page(page_fun, cursor),
         {:ok, seen_names} <- add_tool_names(page_tools, seen_names) do
      page_chunks = [page_tools | page_chunks]

      case next_cursor do
        nil ->
          {:ok, page_chunks |> Enum.reverse() |> Enum.flat_map(& &1)}

        next_cursor when is_binary(next_cursor) ->
          continue_pages(
            page_fun,
            next_cursor,
            seen_cursors,
            seen_names,
            page_chunks,
            pages
          )

        _invalid_cursor ->
          {:error, :invalid_cursor}
      end
    end
  end

  defp continue_pages(page_fun, next_cursor, seen_cursors, seen_names, page_chunks, pages) do
    cond do
      not String.valid?(next_cursor) ->
        {:error, :invalid_cursor}

      MapSet.member?(seen_cursors, next_cursor) ->
        {:error, :cursor_cycle}

      true ->
        fetch_pages(
          page_fun,
          next_cursor,
          MapSet.put(seen_cursors, next_cursor),
          seen_names,
          page_chunks,
          pages + 1
        )
    end
  end

  defp add_tool_names(tools, seen_names) do
    Enum.reduce_while(tools, {:ok, seen_names}, fn
      %{"name" => name}, {:ok, names} when is_binary(name) ->
        if MapSet.member?(names, name) do
          {:halt, {:error, :duplicate_tool_name}}
        else
          {:cont, {:ok, MapSet.put(names, name)}}
        end

      _tool, {:ok, names} ->
        {:cont, {:ok, names}}
    end)
  end

  defp fetch_page(page_fun, cursor) do
    try do
      case page_fun.(cursor) do
        {:ok, %Response{is_error: false, result: %{"tools" => tools} = result}}
        when is_list(tools) ->
          {:ok, tools, Map.get(result, "nextCursor")}

        {:error, _reason} ->
          {:error, :catalog_request_failed}

        _invalid_page ->
          {:error, :invalid_catalog_page}
      end
    rescue
      _exception -> {:error, :catalog_request_failed}
    catch
      _kind, _reason -> {:error, :catalog_request_failed}
    end
  end

  defp validate_name(name) when is_binary(name) do
    if name != "" and String.valid?(name), do: :ok, else: :error
  end

  defp validate_name(_name), do: :error

  defp defaulted_field(raw, key, default, validator) do
    case Map.fetch(raw, key) do
      :error -> {:ok, default}
      {:ok, value} -> validate_field(value, validator)
    end
  end

  defp optional_field(raw, key, validator) do
    case Map.fetch(raw, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> validate_field(value, validator)
    end
  end

  defp validate_field(value, validator) do
    if validator.(value), do: {:ok, value}, else: :error
  end

  defp valid_tool_annotations?(annotations) when is_map(annotations) do
    string_keyed_map?(annotations) and
      valid_optional_map_field?(annotations, "title", &is_binary/1) and
      valid_optional_map_field?(annotations, "readOnlyHint", &is_boolean/1) and
      valid_optional_map_field?(annotations, "destructiveHint", &is_boolean/1) and
      valid_optional_map_field?(annotations, "idempotentHint", &is_boolean/1) and
      valid_optional_map_field?(annotations, "openWorldHint", &is_boolean/1)
  end

  defp valid_tool_annotations?(_annotations), do: false

  defp valid_icons?([]), do: true
  defp valid_icons?([icon | icons]), do: valid_icon?(icon) and valid_icons?(icons)
  defp valid_icons?(_icons), do: false

  defp valid_icon?(%{"src" => src} = icon) when is_binary(src) do
    string_keyed_map?(icon) and
      valid_absolute_uri?(src) and
      valid_optional_map_field?(icon, "mimeType", &is_binary/1) and
      valid_optional_map_field?(icon, "sizes", &string_list?/1) and
      valid_optional_map_field?(icon, "theme", &(&1 in ~w(dark light)))
  end

  defp valid_icon?(_icon), do: false

  defp valid_optional_map_field?(map, key, validator) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> validator.(value)
    end
  end

  defp string_keyed_map?(map), do: Enum.all?(Map.keys(map), &is_binary/1)

  defp string_list?([]), do: true
  defp string_list?([value | values]) when is_binary(value), do: string_list?(values)
  defp string_list?(_values), do: false

  defp valid_absolute_uri?(value) when is_binary(value) do
    String.valid?(value) and
      match?({:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "", URI.new(value))
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp valid_absolute_uri?(_value), do: false
end
