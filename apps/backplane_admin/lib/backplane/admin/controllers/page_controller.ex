defmodule Backplane.Admin.PageController do
  use Backplane.Admin, :controller

  def admin(conn, _params) do
    redirect(conn, to: ~p"/dashboard/overview")
  end

  def not_found(conn, _params) do
    Plug.Conn.send_resp(conn, 404, dgettext("errors", "not found"))
  end

  def legacy_embedding(conn, _params), do: redirect(conn, to: ~p"/llama/embedding")
  def legacy_audio(conn, _params), do: redirect(conn, to: ~p"/llama/audio")

  def legacy_openai(conn, %{"kind" => kind})
      when kind in ~w(decisions images speech transcription realtime) do
    redirect(conn, to: "/llama/openai/#{kind}")
  end

  def legacy_openai(conn, _params), do: not_found(conn, %{})
end
