defmodule Backplane.Skills.ApiRouter do
  @moduledoc """
  HTTP API for archived skills.
  """

  use Plug.Router

  alias Backplane.Skills
  alias Backplane.Skills.{Archive, Skill}
  alias Backplane.Skills.Blob.LocalFS

  plug(Plug.Parsers,
    parsers: [:multipart, :json],
    pass: ["application/x-tar+gzip", "application/gzip", "*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn = fetch_query_params(conn)
    query = conn.query_params["q"]
    tags = parse_tags(conn.query_params["tags"])
    limit = parse_limit(conn.query_params["limit"])

    results = Skills.list(q: query, tags: tags, limit: limit)
    json(conn, 200, %{data: results, cursor: nil})
  end

  get "/:slug/archive" do
    case Skills.archive_stream(slug) do
      {:ok, skill, stream} ->
        filename = "#{skill.slug || skill.id}.tar.gz"

        conn
        |> put_resp_header("content-type", "application/x-tar+gzip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_chunked(200)
        |> stream_chunks(stream)

      {:error, :not_found} ->
        json(conn, 404, %{error: "not_found"})
    end
  end

  get "/:slug" do
    with {:ok, skill} <- Skills.get(slug),
         {:ok, details} <- skill_details(skill) do
      json(conn, 200, %{data: details})
    else
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, reason} -> json(conn, 422, %{error: to_string(reason)})
    end
  end

  post "/" do
    with {:ok, archive, filename, conn} <- request_archive(conn),
         {:ok, skill} <- Skills.ingest_archive(archive, filename: filename) do
      json(conn, 201, %{data: skill_metadata(skill)})
    else
      {:error, :missing_archive, conn} -> json(conn, 422, %{error: "missing_archive"})
      {:error, reason} -> json(conn, 422, %{error: to_string(reason)})
    end
  end

  delete "/:slug" do
    case Skills.delete(slug) do
      {:ok, _skill} -> send_resp(conn, 204, "")
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  defp request_archive(%{params: %{"archive" => %Plug.Upload{} = upload}} = conn) do
    case File.read(upload.path) do
      {:ok, archive} -> {:ok, archive, upload.filename, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_archive(conn) do
    case read_body_chunks(conn, []) do
      {:ok, "", conn} -> {:error, :missing_archive, conn}
      {:ok, archive, conn} -> {:ok, archive, nil, conn}
      {:error, reason, _conn} -> {:error, reason}
    end
  end

  defp read_body_chunks(conn, acc) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
      {:more, chunk, conn} -> read_body_chunks(conn, [chunk | acc])
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp skill_details(%Skill{} = skill) do
    if skill.archive_ref do
      with {:ok, stream} <- LocalFS.get(skill.content_hash),
           archive <- Enum.into(stream, ""),
           {:ok, info} <- Archive.inspect(archive) do
        {:ok,
         skill
         |> skill_metadata()
         |> Map.merge(%{
           files: info.files,
           meta: info.meta
         })}
      end
    else
      {:ok, skill |> skill_metadata() |> Map.merge(%{files: [], meta: skill.meta || %{}})}
    end
  end

  defp skill_metadata(%Skill{} = skill) do
    %{
      id: skill.id,
      slug: skill.slug,
      name: skill.name,
      description: skill.description,
      tags: skill.tags,
      version: skill.version,
      license: skill.license,
      homepage: skill.homepage,
      author: skill.author,
      content_hash: skill.content_hash,
      archive_ref: skill.archive_ref,
      size_bytes: skill.size_bytes,
      file_count: skill.file_count,
      source_kind: skill.source_kind,
      source_uri: skill.source_uri,
      source_rev: skill.source_rev
    }
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []
  defp parse_tags(tags) when is_list(tags), do: Enum.flat_map(tags, &parse_tags/1)

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_limit(nil), do: 10

  defp parse_limit(limit) do
    case Integer.parse(limit) do
      {value, ""} when value > 0 -> min(value, 100)
      _ -> 10
    end
  end

  defp stream_chunks(conn, stream) do
    Enum.reduce_while(stream, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
