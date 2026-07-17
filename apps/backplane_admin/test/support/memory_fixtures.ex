defmodule Backplane.Admin.MemoryFixtures.FailingRepo do
  def all(_query), do: raise("forced memory repository failure")
  def get(_schema, _id), do: raise("forced memory repository failure")
  def one(_query), do: raise("forced memory repository failure")
end

defmodule Backplane.Admin.MemoryFixtures.FailingSettings do
  def get_many(keys), do: Backplane.Settings.get_many(keys)
  def subscribe, do: Backplane.Settings.subscribe()

  def set_if(_key, _value, _expectations),
    do: {:error, :forced_setting_failure}
end

defmodule Backplane.Admin.MemoryFixtures.CrashingSettings do
  def get_many(_keys), do: raise("forced settings read failure")
  def subscribe, do: Backplane.Settings.subscribe()

  def set_if(_key, _value, _expectations),
    do: exit(:forced_settings_write_failure)
end

defmodule Backplane.Admin.MemoryFixtures do
  import Plug.Conn

  alias Backplane.Memory.Events
  alias Backplane.Settings

  @gate_keys [
    "memory.pipeline.enabled",
    "memory.events.enabled",
    "memory.events.dual_write"
  ]

  def setup_memory_auth(%{conn: conn}) do
    previous = %{
      username: Application.fetch_env(:backplane, :admin_username),
      password: Application.fetch_env(:backplane, :admin_password)
    }

    Application.put_env(:backplane, :admin_username, "memory-admin")
    Application.put_env(:backplane, :admin_password, "memory-secret")

    ExUnit.Callbacks.on_exit(fn ->
      restore_application_env(:admin_username, previous.username)
      restore_application_env(:admin_password, previous.password)
    end)

    encoded = Base.encode64("memory-admin:memory-secret")

    {:ok,
     conn:
       put_req_header(
         conn,
         "authorization",
         "Basic #{encoded}"
       )}
  end

  def setup_memory_gates(_context) do
    previous = Map.new(@gate_keys, &{&1, Settings.get(&1)})
    Enum.each(@gate_keys, &assert_ok(Settings.set(&1, false)))

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        assert_ok(Settings.set(key, value))
      end)
    end)

    :ok
  end

  def event_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(
        :stream_id,
        "fixture-stream-#{System.unique_integer([:positive, :monotonic])}"
      )
      |> Map.put_new(:event_type, "task.created")

    {:ok, event} = Events.append(attrs)
    event
  end

  def safe_summary(event) do
    Map.take(event, [
      :id,
      :stream_id,
      :event_type,
      :project,
      :agent_id,
      :session_id,
      :run_id,
      :tool_name,
      :status,
      :occurred_at
    ])
  end

  def fail_memory_reads! do
    previous = Application.fetch_env(:backplane_memory, :repo)

    Application.put_env(
      :backplane_memory,
      :repo,
      Backplane.Admin.MemoryFixtures.FailingRepo
    )

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, repo} -> Application.put_env(:backplane_memory, :repo, repo)
        :error -> Application.delete_env(:backplane_memory, :repo)
      end
    end)

    :ok
  end

  def fail_memory_settings! do
    previous =
      Application.fetch_env(
        :backplane_memory,
        :settings_adapter
      )

    Application.put_env(
      :backplane_memory,
      :settings_adapter,
      Backplane.Admin.MemoryFixtures.FailingSettings
    )

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, adapter} ->
          Application.put_env(
            :backplane_memory,
            :settings_adapter,
            adapter
          )

        :error ->
          Application.delete_env(
            :backplane_memory,
            :settings_adapter
          )
      end
    end)

    :ok
  end

  def crash_memory_settings! do
    previous =
      Application.fetch_env(
        :backplane_memory,
        :settings_adapter
      )

    Application.put_env(
      :backplane_memory,
      :settings_adapter,
      Backplane.Admin.MemoryFixtures.CrashingSettings
    )

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, adapter} ->
          Application.put_env(
            :backplane_memory,
            :settings_adapter,
            adapter
          )

        :error ->
          Application.delete_env(
            :backplane_memory,
            :settings_adapter
          )
      end
    end)

    :ok
  end

  defp restore_application_env(key, {:ok, value}) do
    Application.put_env(:backplane, key, value)
  end

  defp restore_application_env(key, :error) do
    Application.delete_env(:backplane, key)
  end

  defp assert_ok(:ok), do: :ok
  defp assert_ok({:error, reason}), do: raise("setting write failed: #{inspect(reason)}")
end
