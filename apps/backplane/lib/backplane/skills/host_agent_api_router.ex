defmodule Backplane.Skills.HostAgentApiRouter do
  @moduledoc """
  Authenticated HTTP API used by host agents to download skill archives.
  """

  use Plug.Router

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills
  alias Backplane.Skills.{Host, HostAssignment, Hosts, Skill}

  @archive_content_type "application/x-tar+gzip"

  plug(:match)
  plug(:fetch_query_params)
  plug(:auth_host)
  plug(:dispatch)

  get "/skills/:slug/download" do
    case authorized_archive_stream(conn.assigns.host, slug) do
      {:ok, stream} ->
        stream_archive(conn, slug, stream)

      {:error, :not_found} ->
        send_resp(conn, 404, "not found")

      {:error, _reason} ->
        send_resp(conn, 500, "archive error")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp authorized_archive_stream(%Host{} = host, slug) do
    case assigned_archive_skill(host, slug) do
      %Skill{} = skill -> Skills.archive_stream(skill)
      nil -> {:error, :not_found}
    end
  end

  defp assigned_archive_skill(%Host{} = host, slug) do
    HostAssignment
    |> where([assignment], assignment.host_id == ^host.id and assignment.enabled == true)
    |> join(:inner, [assignment], skill in Skill, on: skill.id == assignment.skill_id)
    |> where(
      [_assignment, skill],
      skill.slug == ^slug and skill.enabled == true and skill.source_kind == "archive" and
        not is_nil(skill.archive_ref)
    )
    |> select([_assignment, skill], skill)
    |> Repo.one()
  end

  defp auth_host(conn, _opts) do
    token =
      conn
      |> get_req_header("x-backplane-host-token")
      |> List.first()

    case Hosts.verify_token(token) do
      {:ok, host} -> assign(conn, :host, host)
      :error -> conn |> send_resp(401, "unauthorized") |> halt()
    end
  end

  defp stream_archive(conn, slug, stream) do
    conn =
      conn
      |> put_resp_content_type(@archive_content_type, nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{slug}.tar.gz"))
      |> send_chunked(200)

    Enum.reduce_while(stream, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end
end
