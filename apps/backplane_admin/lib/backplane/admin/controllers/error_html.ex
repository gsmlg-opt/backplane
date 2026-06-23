defmodule Backplane.Admin.ErrorHTML do
  @moduledoc """
  Error pages rendered as HTML.
  """

  use Backplane.Admin, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
