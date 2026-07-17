defmodule Backplane.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @env_vars ~w(
    BACKPLANE_CONFIG
    SECRET_KEY_BASE
    BACKPLANE_ADMIN_USERNAME
    BACKPLANE_ADMIN_PASSWORD
  )

  setup do
    previous_env = Map.new(@env_vars, &{&1, System.get_env(&1)})

    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  @tag :tmp_dir
  test "admin credential environment variables override TOML", %{tmp_dir: tmp_dir} do
    config_path = write_runtime_toml(tmp_dir)

    System.put_env("BACKPLANE_CONFIG", config_path)
    System.put_env("SECRET_KEY_BASE", secret_key_base())
    System.put_env("BACKPLANE_ADMIN_USERNAME", "env-admin")
    System.put_env("BACKPLANE_ADMIN_PASSWORD", "env-secret")

    config = read_runtime_config()

    assert config[:backplane][:admin_username] == "env-admin"
    assert config[:backplane][:admin_password] == "env-secret"
  end

  @tag :tmp_dir
  test "admin credentials fall back to TOML", %{tmp_dir: tmp_dir} do
    config_path = write_runtime_toml(tmp_dir)

    System.put_env("BACKPLANE_CONFIG", config_path)
    System.put_env("SECRET_KEY_BASE", secret_key_base())

    config = read_runtime_config()

    assert config[:backplane][:admin_username] == "toml-admin"
    assert config[:backplane][:admin_password] == "toml-secret"
  end

  @tag :tmp_dir
  test "admin credentials can be configured from env without a TOML file", %{tmp_dir: tmp_dir} do
    System.put_env("BACKPLANE_CONFIG", Path.join(tmp_dir, "missing.toml"))
    System.put_env("SECRET_KEY_BASE", secret_key_base())
    System.put_env("BACKPLANE_ADMIN_USERNAME", "env-admin")
    System.put_env("BACKPLANE_ADMIN_PASSWORD", "env-secret")

    config = read_runtime_config()

    assert config[:backplane][:admin_username] == "env-admin"
    assert config[:backplane][:admin_password] == "env-secret"
  end

  defp read_runtime_config do
    Path.expand("../../../../config/runtime.exs", __DIR__)
    |> Config.Reader.read!(env: :prod)
  end

  defp write_runtime_toml(tmp_dir) do
    path = Path.join(tmp_dir, "backplane.toml")

    File.write!(path, """
    [backplane]
    host = "0.0.0.0"
    port = 4100
    admin_username = "toml-admin"
    admin_password = "toml-secret"

    [database]
    url = "postgres://localhost/backplane_test"
    """)

    path
  end

  defp secret_key_base do
    String.duplicate("runtime-config-test-secret-", 4)
  end
end
