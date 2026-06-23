defmodule Backplane.Api.ErrorHTML do
  @moduledoc """
  Error pages rendered as HTML.
  """

  use Backplane.Api, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
