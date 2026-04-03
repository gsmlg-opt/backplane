defmodule BackplaneWeb.Layouts do
  @moduledoc """
  Root and app layout components for the Backplane admin UI.
  """

  use BackplaneWeb, :html

  embed_templates("layouts/*")
end
