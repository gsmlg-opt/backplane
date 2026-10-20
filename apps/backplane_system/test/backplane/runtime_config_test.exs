defmodule Backplane.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @env_vars ~w(
    BACKPLANE_CONFIG
    BACKPLANE_AUTH_TOKEN
    BACKPLANE_AUTH_TOKENS
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
  test "legacy admin credential settings are ignored", %{tmp_dir: tmp_dir} do
    config_path = write_runtime_toml(tmp_dir)

    System.put_env("BACKPLANE_CONFIG", config_path)
    System.put_env("SECRET_KEY_BASE", secret_key_base())
    System.put_env("BACKPLANE_ADMIN_USERNAME", "env-admin")
    System.put_env("BACKPLANE_ADMIN_PASSWORD", "env-secret")

    config = read_runtime_config()
    backplane_config = Keyword.fetch!(config, :backplane)

    refute Keyword.has_key?(backplane_config, :admin_username)
    refute Keyword.has_key?(backplane_config, :admin_password)
  end

  @tag :tmp_dir
  test "deprecated shared token environment fails before runtime endpoints are configured", %{
    tmp_dir: tmp_dir
  } do
    System.put_env("BACKPLANE_CONFIG", write_runtime_toml(tmp_dir))
    System.put_env("SECRET_KEY_BASE", secret_key_base())

    for name <- ["BACKPLANE_AUTH_TOKEN", "BACKPLANE_AUTH_TOKENS"] do
      System.put_env(name, "never-print-secret")
      error = assert_raise ArgumentError, fn -> read_runtime_config() end
      assert Exception.message(error) =~ name
      refute Exception.message(error) =~ "never-print-secret"
      System.delete_env(name)
    end
  end

  test "application startup rejects shared app configuration before starting children" do
    old = Application.get_env(:backplane, :auth_token)
    Application.put_env(:backplane, :auth_token, "never-print-secret")

    try do
      error = assert_raise ArgumentError, fn -> BackplaneSystem.Application.start(:normal, []) end
      assert Exception.message(error) =~ "auth_token"
      refute Exception.message(error) =~ "never-print-secret"
    after
      if old == nil,
        do: Application.delete_env(:backplane, :auth_token),
        else: Application.put_env(:backplane, :auth_token, old)
    end
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
