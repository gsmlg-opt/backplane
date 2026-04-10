defmodule Backplane.Settings.Encryption do
  @moduledoc """
  AES-256-GCM encryption for credentials and other secrets.
  Derives a 256-bit key from the application's secret_key_base.
  """

  @aad "backplane-v2"

  @doc "Encrypt plaintext. Returns `{iv, ciphertext, tag}` as a single binary."
  @spec encrypt(String.t()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    key = derive_key()
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)
    iv <> tag <> ciphertext
  end

  @doc "Decrypt a binary produced by `encrypt/1`."
  @spec decrypt(binary()) :: {:ok, String.t()} | {:error, :decryption_failed}
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    key = derive_key()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  end

  def decrypt(_), do: {:error, :decryption_failed}

  defp derive_key do
    secret_key_base = fetch_secret_key_base()
    :crypto.hash(:sha256, secret_key_base)
  end

  defp fetch_secret_key_base do
    Application.get_env(:backplane_web, BackplaneWeb.Endpoint)[:secret_key_base] ||
      Application.get_env(:backplane, :secret_key_base) ||
      raise "secret_key_base not configured"
  end
end
