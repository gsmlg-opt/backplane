defmodule Backplane.HostAgent.Memory.Spool.Cipher do
  @moduledoc false

  @prefix "bpenc:v1:"
  @aad_prefix "backplane.capture_spool.envelope:v1\0"
  @verifier_aad "backplane.capture_spool.metadata:key-verifier:v1"
  @verifier_plaintext "backplane.capture_spool.key-verifier:v1"
  @nonce_bytes 12
  @tag_bytes 16

  def resolve(nil), do: {:ok, nil}

  def resolve(env_name) when is_binary(env_name) do
    with :ok <- validate_env_name(env_name),
         {:ok, encoded_key} <- fetch_key(env_name),
         {:ok, key} <- decode_key(encoded_key) do
      {:ok, facility(key)}
    end
  end

  def resolve(_env_name), do: {:error, {:invalid_spool_encryption_key_env, :expected_name}}

  def encrypted?(value) when is_binary(value), do: String.starts_with?(value, @prefix)

  def ciphertext?(value) when is_binary(value), do: String.starts_with?(value, "bpenc:")

  def encrypt(%{encrypt: encrypt}, plaintext, event_id), do: encrypt.(plaintext, aad(event_id))

  def decrypt(%{decrypt: decrypt}, ciphertext, event_id),
    do: decrypt.(ciphertext, aad(event_id))

  def encrypt_verifier(%{encrypt: encrypt}),
    do: encrypt.(@verifier_plaintext, @verifier_aad)

  def verify(%{decrypt: decrypt}, ciphertext) do
    case decrypt.(ciphertext, @verifier_aad) do
      {:ok, @verifier_plaintext} -> :ok
      {:ok, _other} -> {:error, :invalid_spool_encryption_verifier}
      {:error, _reason} = error -> error
    end
  end

  defp facility(key) do
    %{
      encrypt: fn plaintext, aad -> encrypt_with_key(key, plaintext, aad) end,
      decrypt: fn ciphertext, aad -> decrypt_with_key(key, ciphertext, aad) end
    }
  end

  defp encrypt_with_key(key, plaintext, aad) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, true)

    @prefix <> Base.encode64(nonce <> tag <> ciphertext)
  end

  defp decrypt_with_key(key, @prefix <> encoded, aad) do
    with {:ok, payload} <- Base.decode64(encoded),
         <<nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> <-
           payload,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false) do
      {:ok, plaintext}
    else
      :error -> {:error, :spool_encryption_authentication_failed}
      _invalid -> {:error, :invalid_spool_ciphertext}
    end
  end

  defp decrypt_with_key(_key, _ciphertext, _aad),
    do: {:error, :unsupported_spool_ciphertext_version}

  defp aad(event_id), do: @aad_prefix <> event_id

  defp validate_env_name(env_name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, env_name),
      do: :ok,
      else: {:error, {:invalid_spool_encryption_key_env, :invalid_name}}
  end

  defp fetch_key(env_name) do
    case System.get_env(env_name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:spool_encryption_key_missing, env_name}}
    end
  end

  defp decode_key(encoded_key) do
    case Base.decode64(encoded_key) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      {:ok, _key} -> {:error, {:invalid_spool_encryption_key, :expected_32_bytes}}
      :error -> {:error, {:invalid_spool_encryption_key, :invalid_base64}}
    end
  end
end
