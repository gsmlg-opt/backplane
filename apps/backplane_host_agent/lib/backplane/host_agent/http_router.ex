defmodule Backplane.HostAgent.HttpRouter do
  @moduledoc false

  @behaviour Plug

  alias Backplane.HostAgent.Diagnostics.Ingress
  alias Backplane.HostAgent.MemoryRouter

  @impl true
  def init(opts), do: %{diagnostics: Ingress.init(opts), memory: MemoryRouter.init([])}

  @impl true
  def call(%{path_info: ["diagnostics", "v1" | _]} = conn, state),
    do: Ingress.call(conn, state.diagnostics)

  def call(conn, state), do: MemoryRouter.call(conn, state.memory)
end
