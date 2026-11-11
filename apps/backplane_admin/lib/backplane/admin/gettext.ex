defmodule Backplane.Admin.Gettext do
  @moduledoc """
  Gettext backend for the admin UI.

  English (`en`) is the default and only shipped locale; msgids are English
  source text. Domains: `common`, `navigation`, `admin`, `user`, `errors`.
  """
  use Gettext.Backend, otp_app: :backplane_admin
end
