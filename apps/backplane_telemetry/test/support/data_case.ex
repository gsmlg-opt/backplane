defmodule BackplaneTelemetry.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Backplane.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import BackplaneTelemetry.DataCase
    end
  end

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    ensure_settings_started()
    ensure_observability_settings_started()
    :ok
  end

  def ensure_settings_started do
    case Process.whereis(Backplane.Settings) do
      nil ->
        {:ok, _pid} = start_supervised({Backplane.Settings, []})
        send(Backplane.Settings, :seed_and_load)
        :sys.get_state(Backplane.Settings)

      _pid ->
        send(Backplane.Settings, :seed_and_load)
        :sys.get_state(Backplane.Settings)
    end
  end

  def ensure_observability_settings_started do
    case Process.whereis(Backplane.Observability.Settings) do
      nil -> start_supervised!(Backplane.Observability.Settings)
      _pid -> :ok
    end
  end
end
