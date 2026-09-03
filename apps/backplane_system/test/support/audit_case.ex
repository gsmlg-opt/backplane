defmodule BackplaneSystem.AuditCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using opts do
    quote do
      use BackplaneSystem.DataCase, unquote(opts)
      import BackplaneSystem.AuditCase

      alias Backplane.Audit.{Buffer, Writer}
    end
  end

  setup tags do
    if tags[:audit_writer] do
      start_audit_writer!(tags)

      on_exit(fn -> stop_audit_writer!() end)
    end

    :ok
  end

  @doc false
  def start_audit_writer!(tags \\ %{}) do
    stop_audit_writer!()

    capacity = Map.get(tags, :buffer_capacity, 100)

    {:ok, _} =
      GenServer.start_link(Backplane.Audit.Buffer, [name: :audit, capacity: capacity], name: :audit)

    {:ok, _} =
      Backplane.Audit.Writer.start_link(
        batch_size: Map.get(tags, :batch_size, 50),
        flush_interval_ms: Map.get(tags, :flush_interval_ms, 60_000),
        subscribe_settings: false
      )

    :ok
  end

  @doc false
  def stop_audit_writer! do
    for name <- [Backplane.Audit.Writer, :audit] do
      case Process.whereis(name) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 5_000)
      end
    end

    :persistent_term.erase({Backplane.Audit.Buffer, :audit})
    :ok
  end

  @doc false
  def flush_audit! do
    Backplane.Audit.Writer.flush()
  end
end
