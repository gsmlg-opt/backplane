defmodule Backplane.Skills.ApiRouter do
  @moduledoc """
  REST API for archive-backed skills.
  """

  use Plug.Router

  alias Backplane.Skills
  alias Backplane.Skills.Skill

  @raw_archive_content_type "application/x-tar+gzip"
  @read_body_opts [length: 64_000, read_length: 64_000, read_timeout: 15_000]

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn = fetch_query_params(conn)
    params = conn.query_params

    skills =
      params
      |> search_opts()
      |> then(&Skills.search(Map.get(params, "q", ""), &1))

    json(conn, 200, %{data: Enum.map(skills, &serialize_metadata/1)})
  end

  get "/:slug/archive" do
    with {:ok, skill} <- Skills.get_by_slug(slug),
         {:ok, stream} <- Skills.archive_stream(skill) do
      stream_archive(conn, skill, stream)
    else
      {:error, :not_found} -> json(conn, 404, %{error: "not found"})
      {:error, reason} -> json(conn, 500, %{error: format_reason(reason)})
    end
  end

  get "/export" do
    path = temp_archive_path("backplane-skills-export")

    try do
      case Skills.export(path: path) do
        {:ok, _result} -> stream_collection(conn, path)
        {:error, reason} -> json(conn, 500, %{error: format_reason(reason)})
      end
    after
      File.rm(path)
    end
  end

  get "/:slug" do
    with {:ok, skill} <- Skills.get_by_slug(slug),
         {:ok, detail} <- serialize_detail(skill) do
      json(conn, 200, detail)
    else
      {:error, :not_found} -> json(conn, 404, %{error: "not found"})
      {:error, reason} -> json(conn, 500, %{error: format_reason(reason)})
    end
  end

  post "/import" do
    case import_source(conn) do
      {:ok, conn, collection, cleanup} ->
        try do
          case Skills.import(collection, []) do
            {:ok, %{count: count, skills: skills}} ->
              json(conn, 201, %{count: count, data: Enum.map(skills, &serialize_metadata/1)})

            {:error, reason} ->
              json(conn, 422, %{error: format_reason(reason)})
          end
        after
          cleanup.()
        end

      {:error, conn, reason} ->
        json(conn, 422, %{error: format_reason(reason)})
    end
  end

  post "/" do
    case upload_source(conn) do
      {:ok, conn, archive, cleanup} ->
        try do
          case Skills.ingest_archive(archive, []) do
            {:ok, skill} -> json(conn, 201, serialize_metadata(skill))
            {:error, reason} -> json(conn, 422, %{error: format_reason(reason)})
          end
        after
          cleanup.()
        end

      {:error, conn, reason} ->
        json(conn, 422, %{error: format_reason(reason)})
    end
  end

  delete "/:slug" do
    with {:ok, skill} <- Skills.get_by_slug(slug),
         {:ok, _deleted} <- Skills.delete(skill) do
      json(conn, 200, %{ok: true})
    else
      {:error, :not_found} -> json(conn, 404, %{error: "not found"})
      {:error, reason} -> json(conn, 500, %{error: format_reason(reason)})
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  defp search_opts(params) do
    [
      tags: parse_tags(Map.get(params, "tags")),
      limit: parse_limit(Map.get(params, "limit"))
    ]
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_limit(nil), do: 20
  defp parse_limit(""), do: 20

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> value |> max(1) |> min(100)
      _ -> 20
    end
  end

  defp upload_source(conn) do
    cond do
      raw_archive_upload?(conn) ->
        read_raw_archive(conn)

      upload = multipart_archive(conn) ->
        {:ok, conn, upload, fn -> :ok end}

      true ->
        {:error, conn, :missing_archive}
    end
  end

  defp import_source(conn) do
    if raw_archive_upload?(conn) do
      read_raw_archive(conn)
    else
      {:error, conn, :missing_archive}
    end
  end

  defp raw_archive_upload?(conn) do
    conn
    |> get_req_header("content-type")
    |> Enum.any?(&(media_type(&1) == @raw_archive_content_type))
  end

  defp media_type(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp multipart_archive(%{body_params: %{"archive" => %Plug.Upload{} = upload}}), do: upload
  defp multipart_archive(%{body_params: %{archive: %Plug.Upload{} = upload}}), do: upload
  defp multipart_archive(_conn), do: nil

  defp read_raw_archive(conn) do
    path = temp_archive_path("backplane-skill-upload")

    case File.open(path, [:write, :binary], &read_body_chunks(conn, &1)) do
      {:ok, {:ok, conn}} ->
        {:ok, conn, path, fn -> File.rm(path) end}

      {:ok, {:error, conn, reason}} ->
        File.rm(path)
        {:error, conn, reason}

      {:error, reason} ->
        {:error, conn, reason}
    end
  end

  defp read_body_chunks(conn, io) do
    case Plug.Conn.read_body(conn, @read_body_opts) do
      {:ok, chunk, conn} ->
        IO.binwrite(io, chunk)
        {:ok, conn}

      {:more, chunk, conn} ->
        IO.binwrite(io, chunk)
        read_body_chunks(conn, io)

      {:error, reason} ->
        {:error, conn, reason}
    end
  end

  defp stream_archive(conn, %Skill{} = skill, stream) do
    conn =
      conn
      |> put_resp_content_type(@raw_archive_content_type, nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{skill.slug}.tar.gz"))
      |> send_chunked(200)

    Enum.reduce_while(stream, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp stream_collection(conn, path) do
    stream = File.stream!(path, [], 2048)

    conn =
      conn
      |> put_resp_content_type(@raw_archive_content_type, nil)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="skills-collection.tar.gz")
      )
      |> send_chunked(200)

    Enum.reduce_while(stream, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp serialize_detail(%Skill{} = skill) do
    with {:ok, files} <- archive_files(skill) do
      detail =
        skill
        |> serialize_metadata()
        |> Map.put(:files, files)

      {:ok, detail}
    else
      {:error, reason} -> {:error, {:archive_files, reason}}
    end
  end

  defp archive_files(%Skill{source_kind: "archive", archive_ref: archive_ref} = skill)
       when is_binary(archive_ref) do
    Skills.archive_files(skill)
  end

  defp archive_files(%Skill{}) do
    {:ok, []}
  end

  defp serialize_metadata(%Skill{} = skill) do
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
      source_kind: skill.source_kind
    }
  end

  defp serialize_metadata(skill) when is_map(skill) do
    skill
    |> Map.take([
      :id,
      :slug,
      :name,
      :description,
      :tags,
      :version,
      :license,
      :homepage,
      :content_hash,
      :archive_ref,
      :size_bytes,
      :file_count
    ])
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp temp_archive_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.tar.gz")
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
