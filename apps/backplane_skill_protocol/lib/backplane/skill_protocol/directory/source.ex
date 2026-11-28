defmodule Backplane.SkillProtocol.Directory.Source do
  @moduledoc false

  alias Backplane.SkillProtocol.{Client, Error}
  alias Backplane.SkillProtocol.Source.{Backplane, Local}

  @remote_max_pages 100

  def normalize({id, source}), do: normalize({id, source, 100})

  def normalize({id, source, precedence})
      when is_binary(id) and id != "" and is_integer(precedence) do
    with {:ok, source} <- normalize_source(id, source), do: {:ok, {{id, source}, precedence}}
  end

  def normalize(_source), do: error(:invalid_request, "invalid directory source")

  defp normalize_source(id, {:local, path}), do: normalize_source(id, {:local, path, []})

  defp normalize_source(_id, {:local, path, opts}) when is_binary(path) and path != "" do
    with {:ok, options} <- Local.index_options(opts),
         do: {:ok, {:local, Path.expand(path), options}}
  end

  defp normalize_source(id, %Backplane{client: %Client{source_id: id}} = source),
    do: {:ok, {:remote, source}}

  defp normalize_source(_id, _source), do: error(:invalid_request, "invalid directory source")

  def refresh({id, {:local, path, opts}}, records, changes, before_scan),
    do: Local.index(path, id, opts, records, changes, before_scan)

  def refresh({_id, {:remote, source}}, _records, _changes, _before_scan) do
    with {:ok, descriptors} <- catalog_pages(source, nil, MapSet.new(), [], @remote_max_pages) do
      {:ok, %{descriptors: descriptors, diagnostics: [], records: nil}}
    end
  end

  defp catalog_pages(_source, _cursor, _seen, _pages, 0),
    do: error(:limit_exceeded, "remote directory page limit exceeded")

  defp catalog_pages(source, cursor, seen, pages, remaining) do
    with {:ok, %{data: descriptors, next_cursor: next_cursor}} <-
           Backplane.catalog(source,
             view: :always,
             cursor: cursor,
             limit: 100,
             fields: [:argument_hint]
           ) do
      pages = [descriptors | pages]

      cond do
        is_nil(next_cursor) ->
          {:ok, pages |> Enum.reverse() |> List.flatten()}

        MapSet.member?(seen, next_cursor) ->
          error(:invalid_request, "remote catalog cursor repeated")

        true ->
          catalog_pages(source, next_cursor, MapSet.put(seen, next_cursor), pages, remaining - 1)
      end
    end
  end

  defp error(code, message), do: {:error, Error.new(code, :directory, message)}
end
