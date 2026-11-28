defmodule Backplane.CDP.MCP.SourceMap do
  @moduledoc """
  Resolves original source coordinates through bounded version 3 source maps.

  Coordinates in the public API are one-based. An explicit source column uses
  the closest preceding mapping on that source line. An omitted column selects
  the first mapped column on the line. Embedded indexed sections are supported.
  """

  import Bitwise

  @max_bytes 512 * 1024
  @max_urls_bytes 2 * 1024 * 1024
  @max_url_bytes 16_384
  @max_sources 10_000
  @max_names 50_000
  @max_segments 100_000
  @max_maps 128
  @max_depth 8
  @max_coordinate 2_147_483_647
  @alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  @digits @alphabet |> :binary.bin_to_list() |> Enum.with_index() |> Map.new()

  @type resolution ::
          :no_source
          | {:ok, %{url: String.t(), line: pos_integer(), column: pos_integer()}}
          | {:error, String.t()}

  @spec resolve(map() | String.t(), String.t(), String.t(), pos_integer(), pos_integer() | nil) ::
          resolution()
  def resolve(map_json, map_url, requested_url, line, column) do
    with :ok <- position(line, column),
         {:ok, map} <- decode(map_json),
         {:ok, base} <- absolute_url(map_url),
         {:ok, requested} <- requested_url(requested_url, base),
         {:ok, state} <-
           walk(
             map,
             base,
             {0, 0},
             nil,
             0,
             %{
               sources: MapSet.new(),
               points: [],
               maps: 0,
               source_count: 0,
               url_bytes: 0,
               mapping_bytes: 0,
               segments: 0
             },
             line - 1
           ),
         {:ok, source} <- select_source(state.sources, requested),
         {:ok, point} <- select_point(state.points, source, column) do
      {:ok, %{url: source, line: point.line + 1, column: point.column + 1}}
    end
  end

  defp position(line, column)
       when is_integer(line) and line in 1..@max_coordinate and
              (is_nil(column) or (is_integer(column) and column in 1..@max_coordinate)),
       do: :ok

  defp position(_line, _column),
    do: {:error, "Source coordinates must be positive one-based integers"}

  defp decode(map) when is_map(map), do: {:ok, map}

  defp decode(json) when is_binary(json) and byte_size(json) <= @max_bytes do
    case Formata.JSON.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, "Invalid source map JSON"}
    end
  end

  defp decode(_map), do: {:error, "Source map exceeds its size limit or is not an object"}

  defp walk(map, base, offset, boundary, depth, state, requested_line) when is_map(map) do
    cond do
      depth > @max_depth or state.maps >= @max_maps ->
        {:error, "Source map section limit exceeded"}

      map["version"] != 3 ->
        {:error, "Only version 3 source maps are supported"}

      Map.has_key?(map, "sections") and Map.has_key?(map, "mappings") ->
        {:error, "Source map cannot contain both sections and mappings"}

      Map.has_key?(map, "sections") ->
        indexed(
          map["sections"],
          base,
          offset,
          boundary,
          depth,
          %{state | maps: state.maps + 1},
          requested_line
        )

      true ->
        flat(map, base, offset, boundary, %{state | maps: state.maps + 1}, requested_line)
    end
  end

  defp walk(_map, _base, _offset, _boundary, _depth, _state, _requested_line),
    do: {:error, "Invalid source map section"}

  defp indexed(sections, base, offset, boundary, depth, state, requested_line)
       when is_list(sections) and length(sections) <= @max_maps do
    with {:ok, entries} <- section_entries(sections, offset, boundary) do
      next_entries = Enum.drop(entries, 1) ++ [nil]

      entries
      |> Enum.zip(next_entries)
      |> Enum.reduce_while({:ok, state}, fn {{map, position}, next}, {:ok, state} ->
        next_boundary = if next, do: elem(next, 1), else: boundary

        case walk(map, base, position, next_boundary, depth + 1, state, requested_line) do
          {:ok, state} -> {:cont, {:ok, state}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp indexed(_sections, _base, _offset, _boundary, _depth, _state, _requested_line),
    do: {:error, "Invalid or excessive indexed source map sections"}

  defp section_entries(sections, offset, boundary) do
    result =
      Enum.reduce_while(sections, {:ok, [], nil}, fn section, {:ok, entries, previous} ->
        case section do
          %{"offset" => %{"line" => line, "column" => column}, "map" => map}
          when is_integer(line) and line in 0..@max_coordinate and
                 is_integer(column) and column in 0..@max_coordinate and is_map(map) ->
            position = add_offset(offset, {line, column})

            if valid_generated?(position, boundary) and (previous == nil or position > previous) do
              {:cont, {:ok, [{map, position} | entries], position}}
            else
              {:halt, {:error, "Source map sections have invalid or overlapping offsets"}}
            end

          %{"url" => _url} ->
            {:halt, {:error, "External source map sections are unsupported"}}

          _ ->
            {:halt, {:error, "Invalid indexed source map section"}}
        end
      end)

    case result do
      {:ok, entries, _previous} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp flat(map, base, offset, boundary, state, requested_line) do
    names = Map.get(map, "names", [])

    with :ok <- mapping_size(map["mappings"], state.mapping_bytes),
         :ok <- names(names),
         {:ok, root} <- source_root(base, map["sourceRoot"]),
         {:ok, sources, state} <- sources(map["sources"], root, state) do
      state = %{state | mapping_bytes: state.mapping_bytes + byte_size(map["mappings"])}
      delta = %{source: 0, original_line: 0, original_column: 0, name: 0}
      tables = %{sources: List.to_tuple(sources), names: length(names)}

      map["mappings"]
      |> :binary.split(";", [:global])
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, state, delta}, fn {line, generated_line}, {:ok, state, delta} ->
        case mapping_line(
               line,
               generated_line,
               tables,
               offset,
               boundary,
               state,
               delta,
               requested_line
             ) do
          {:ok, state, delta} -> {:cont, {:ok, state, delta}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, state, _delta} -> {:ok, state}
        error -> error
      end
    end
  end

  defp mapping_size(mappings, previous)
       when is_binary(mappings) and byte_size(mappings) + previous <= @max_bytes,
       do: :ok

  defp mapping_size(_mappings, _previous),
    do: {:error, "Invalid source map mappings or mapping size limit exceeded"}

  defp names(names) when is_list(names) and length(names) <= @max_names do
    if Enum.all?(names, &is_binary/1), do: :ok, else: {:error, "Invalid source map names"}
  end

  defp names(_names), do: {:error, "Invalid or excessive source map names"}

  defp sources(sources, root, state)
       when is_list(sources) and length(sources) + state.source_count <= @max_sources do
    result =
      Enum.reduce_while(sources, {:ok, [], state}, fn source, {:ok, urls, state} ->
        with {:ok, url} <- source_url(root, source),
             true <- state.url_bytes + byte_size(url) <= @max_urls_bytes do
          state = %{
            state
            | sources: MapSet.put(state.sources, url),
              source_count: state.source_count + 1,
              url_bytes: state.url_bytes + byte_size(url)
          }

          {:cont, {:ok, [url | urls], state}}
        else
          false -> {:halt, {:error, "Resolved source map URL limit exceeded"}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, urls, state} -> {:ok, Enum.reverse(urls), state}
      error -> error
    end
  end

  defp sources(_sources, _root, _state), do: {:error, "Invalid or excessive source map sources"}

  defp mapping_line("", _line, _tables, _offset, _boundary, state, delta, _requested_line),
    do: {:ok, state, delta}

  defp mapping_line(line, generated_line, tables, offset, boundary, state, delta, requested_line) do
    line
    |> :binary.split(",", [:global])
    |> Enum.reduce_while({:ok, state, delta, 0}, fn segment,
                                                    {:ok, state, delta, generated_column} ->
      with true <- state.segments < @max_segments,
           {:ok, values} <- values(segment, []),
           {:ok, generated_column, delta, point} <-
             segment(values, generated_line, generated_column, tables, offset, boundary, delta) do
        points =
          if point && point.original_line == requested_line,
            do: [point | state.points],
            else: state.points

        {:cont,
         {:ok, %{state | points: points, segments: state.segments + 1}, delta, generated_column}}
      else
        false -> {:halt, {:error, "Source map segment limit exceeded"}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state, delta, _column} -> {:ok, state, delta}
      error -> error
    end
  end

  defp segment([column_delta | rest], line, column, tables, offset, boundary, delta)
       when column_delta >= 0 and length(rest) in [0, 3, 4] do
    column = column + column_delta
    generated = add_offset(offset, {line, column})

    if valid_generated?(generated, boundary) do
      original(rest, generated, column, tables, delta)
    else
      {:error,
       "Source map generated coordinates overlap a section or exceed the coordinate limit"}
    end
  end

  defp segment(_values, _line, _column, _tables, _offset, _boundary, _delta),
    do: {:error, "Invalid source map segment"}

  defp original([], _generated, column, _tables, delta), do: {:ok, column, delta, nil}

  defp original(
         [source, line, column | name],
         {generated_line, generated_column},
         generated_local_column,
         tables,
         delta
       ) do
    source = delta.source + source
    line = delta.original_line + line
    column = delta.original_column + column
    name_index = delta.name + List.first(name, 0)

    if source >= 0 and source < tuple_size(tables.sources) and
         line in 0..@max_coordinate and column in 0..@max_coordinate and
         (name == [] or (name_index >= 0 and name_index < tables.names)) do
      point = %{
        url: elem(tables.sources, source),
        original_line: line,
        original_column: column,
        line: generated_line,
        column: generated_column
      }

      {:ok, generated_local_column,
       %{source: source, original_line: line, original_column: column, name: name_index}, point}
    else
      {:error, "Invalid source map source index or original coordinates"}
    end
  end

  defp values("", []), do: {:error, "Empty source map segment"}
  defp values("", values), do: {:ok, Enum.reverse(values)}

  defp values(_segment, values) when length(values) >= 5,
    do: {:error, "Source map segment has too many fields"}

  defp values(segment, values) do
    with {:ok, value, rest} <- vlq(segment, 0, 0), do: values(rest, [value | values])
  end

  defp vlq(<<char, rest::binary>>, value, shift) when shift <= 30 do
    case @digits[char] do
      nil ->
        {:error, "Invalid base64 VLQ source map digit"}

      digit ->
        value = value ||| (digit &&& 31) <<< shift

        if (digit &&& 32) == 0 do
          decoded = value >>> 1
          decoded = if (value &&& 1) == 1, do: -decoded, else: decoded

          if abs(decoded) <= @max_coordinate,
            do: {:ok, decoded, rest},
            else: {:error, "Source map VLQ integer exceeds its limit"}
        else
          vlq(rest, value, shift + 5)
        end
    end
  end

  defp vlq(_segment, _value, _shift),
    do: {:error, "Unterminated or excessive source map VLQ integer"}

  defp add_offset({base_line, base_column}, {line, column}),
    do: {base_line + line, column + if(line == 0, do: base_column, else: 0)}

  defp valid_generated?({line, column} = position, boundary),
    do:
      line in 0..@max_coordinate and column in 0..@max_coordinate and
        (boundary == nil or position < boundary)

  defp absolute_url(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme} = uri} when is_binary(scheme) -> {:ok, uri}
      _ -> {:error, "Source map URL must be an absolute URL"}
    end
  end

  defp absolute_url(_url), do: {:error, "Invalid source map URL"}

  defp source_root(base, root) when root in [nil, ""], do: {:ok, base}

  defp source_root(base, root) when is_binary(root) do
    directory = if String.ends_with?(root, "/"), do: root, else: root <> "/"
    with {:ok, url} <- source_url(base, directory), do: {:ok, URI.parse(url)}
  end

  defp source_root(_base, _root), do: {:error, "Invalid source map sourceRoot"}

  defp source_url(base, source) when is_binary(source) and byte_size(source) <= @max_url_bytes do
    with {:ok, uri} <- URI.new(source),
         url = base |> URI.merge(uri) |> URI.to_string(),
         true <- byte_size(url) <= @max_url_bytes do
      {:ok, url}
    else
      _ -> {:error, "Invalid source map source URL"}
    end
  end

  defp source_url(_base, _source), do: {:error, "Invalid source map source URL"}

  defp requested_url(url, base)
       when is_binary(url) and url != "" and byte_size(url) <= @max_url_bytes do
    case URI.new(url) do
      {:ok, %URI{scheme: nil, host: nil, path: path} = uri} when is_binary(path) and path != "" ->
        with {:ok, canonical} <- source_url(base, url), do: {:ok, {:suffix, uri, canonical}}

      {:ok, _uri} ->
        with {:ok, canonical} <- source_url(base, url), do: {:ok, {:exact, canonical}}

      _ ->
        {:error, "Invalid requested source URL"}
    end
  end

  defp requested_url(_url, _base), do: {:error, "A source URL is required"}

  defp select_source(sources, {:exact, requested}) do
    if MapSet.member?(sources, requested), do: {:ok, requested}, else: :no_source
  end

  defp select_source(sources, {:suffix, requested, canonical}) do
    suffix = String.trim_leading(requested.path, "./") |> String.trim_leading("/")

    matches =
      if MapSet.member?(sources, canonical) do
        [canonical]
      else
        Enum.filter(sources, fn url ->
          uri = URI.parse(url)
          path = uri.path || ""

          (path == suffix or String.ends_with?(path, "/" <> suffix)) and
            (requested.query == nil or uri.query == requested.query) and
            (requested.fragment == nil or uri.fragment == requested.fragment)
        end)
      end

    case matches do
      [] ->
        :no_source

      [url] ->
        {:ok, url}

      _ ->
        {:error,
         "Source path matches multiple sources. Specify a longer path or an absolute URL."}
    end
  end

  defp select_point(points, source, column) do
    points = Enum.filter(points, &(&1.url == source))
    points = if column, do: Enum.filter(points, &(&1.original_column < column)), else: points

    original_column =
      case points do
        [] ->
          nil

        _ ->
          if column,
            do: points |> Enum.map(& &1.original_column) |> Enum.max(),
            else: points |> Enum.map(& &1.original_column) |> Enum.min()
      end

    matches = Enum.filter(points, &(&1.original_column == original_column))

    case matches do
      [] -> {:error, "No generated mapping exists at the requested source line and column"}
      _ -> {:ok, Enum.min_by(matches, &{&1.line, &1.column})}
    end
  end
end
