defmodule Backplane.Api.Gettext do
  @moduledoc """
  Gettext backend for the public API HTML pages.

  English (`en`) is the default and only shipped locale; msgids are English
  source text. Domains: `common`, `navigation`, `admin`, `user`, `errors`.
  """
  use Gettext.Backend, otp_app: :backplane_api
end
