defmodule Backplane.Settings.EncryptionConfigTest do
  use ExUnit.Case, async: false

  alias Backplane.Settings.Encryption

  setup do
    old_secret = Application.get_env(:backplane, :secret_key_base)

    on_exit(fn ->
      restore_env(:backplane, :secret_key_base, old_secret)
    end)

    :ok
  end

  test "encrypts and decrypts using the core backplane secret" do
    Application.put_env(:backplane, :secret_key_base, String.duplicate("core-secret", 8))

    encrypted = Encryption.encrypt("secret-value")

    assert {:ok, "secret-value"} = Encryption.decrypt(encrypted)
  end

  test "raises when the core secret is missing" do
    Application.delete_env(:backplane, :secret_key_base)

    assert_raise RuntimeError, "secret_key_base not configured", fn ->
      Encryption.encrypt("secret-value")
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
