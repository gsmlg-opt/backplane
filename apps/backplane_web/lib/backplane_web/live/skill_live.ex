defmodule BackplaneWeb.SkillLive do
  use BackplaneWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/admin/skill")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div aria-label="Skill"></div>
    """
  end
end
