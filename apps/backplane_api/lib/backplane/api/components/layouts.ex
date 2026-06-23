defmodule Backplane.Api.Layouts do
  @moduledoc """
  Layouts for the public/API endpoint.
  """

  use Backplane.Api, :html

  embed_templates("layouts/*")
end
