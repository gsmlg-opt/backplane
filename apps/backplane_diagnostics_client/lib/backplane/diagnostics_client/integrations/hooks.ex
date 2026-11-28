defmodule Backplane.DiagnosticsClient.Integrations.Hooks do
  @moduledoc false

  use GenServer

  alias Backplane.DiagnosticsClient.Integrations.{Logger, Phoenix}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    hook_opts = [reporter: opts[:name], repository_root: opts[:repository_root]]

    installed =
      Enum.filter(Keyword.get(opts, :hooks, [:logger]), fn
        :logger -> Logger.attach(__MODULE__, hook_opts) == :ok
        :phoenix -> Phoenix.attach(__MODULE__, hook_opts) == :ok
      end)

    {:ok, installed}
  end

  @impl true
  def terminate(_reason, installed) do
    Enum.each(installed, fn
      :logger -> Logger.detach(__MODULE__)
      :phoenix -> Phoenix.detach(__MODULE__)
    end)
  end
end
