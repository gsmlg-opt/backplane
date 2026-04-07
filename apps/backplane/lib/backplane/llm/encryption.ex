defmodule Backplane.LLM.Encryption do
  @moduledoc """
  AES-256-GCM encryption for LLM provider API keys.
  """

  @aad "backplane_llm_api_key"

  @doc "Derive a 32-byte key from a secret_key_base string."
  @spec derive_key(String.t()) :: binary()
  def derive_key(secret) when byte_size(secret) >= 32 do
    :crypto.hash(:sha256, secret)
  end

  @doc "Encrypt plaintext using AES-256-GCM with a random 12-byte IV."
  @spec encrypt(String.t(), binary()) :: binary()
  def encrypt(plaintext, key) when is_binary(plaintext) and byte_size(key) == 32 do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @doc "Decrypt a blob encrypted by encrypt/2. Returns {:ok, plaintext} or :error."
  @spec decrypt(binary(), binary()) :: {:ok, String.t()} | :error
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>, key)
      when byte_size(key) == 32 do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def decrypt(_, _), do: :error

  @doc "Get the encryption key from application config."
  @spec get_key() :: binary()
  def get_key do
    secret =
      Application.get_env(:backplane, :secret_key_base) ||
        Application.get_env(:backplane_web, BackplaneWeb.Endpoint)[:secret_key_base] ||
        raise "No secret_key_base configured for LLM API key encryption"

    derive_key(secret)
  end
end
