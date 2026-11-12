defmodule Backplane.Oauth.Supervisor do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      Backplane.Oauth.Cache,
      {Finch, name: OpenIDHttpClient}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Backplane.Oauth.Supervisor)
  end
end
