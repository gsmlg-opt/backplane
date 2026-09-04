defmodule Backplane.LLM.RequestAuthorizationPlug do
  @moduledoc "Common request authentication and resource authorization for LLM routes."

  @behaviour Plug

  alias Backplane.LLM.ResourceAuthorization

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> Backplane.Transport.CORS.call(Backplane.Transport.CORS.init([]))
    |> Backplane.Auth.ResourceAuthPlug.call(%{
      resource: :v1,
      required_scope: {Backplane.LLM.ResourceAuthorization, :required_scope, []}
    })
    |> ResourceAuthorization.call(ResourceAuthorization.init([]))
  end
end
