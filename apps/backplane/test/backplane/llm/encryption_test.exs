defmodule Backplane.LLM.EncryptionTest do
  use ExUnit.Case, async: true

  alias Backplane.LLM.Encryption

  describe "encrypt/decrypt roundtrip" do
    test "encrypts and decrypts a key" do
      key = Encryption.derive_key("test_secret_key_base_that_is_long_enough_32chars!")
      plaintext = "sk-ant-api03-abc123xyz"

      ciphertext = Encryption.encrypt(plaintext, key)
      assert is_binary(ciphertext)
      assert ciphertext != plaintext

      assert {:ok, ^plaintext} = Encryption.decrypt(ciphertext, key)
    end

    test "produces different ciphertext for same plaintext (random IV)" do
      key = Encryption.derive_key("test_secret_key_base_that_is_long_enough_32chars!")
      plaintext = "sk-ant-api03-abc123xyz"

      ct1 = Encryption.encrypt(plaintext, key)
      ct2 = Encryption.encrypt(plaintext, key)

      assert ct1 != ct2
    end

    test "returns error on tampered ciphertext" do
      key = Encryption.derive_key("test_secret_key_base_that_is_long_enough_32chars!")
      ciphertext = Encryption.encrypt("sk-ant-api03-abc123xyz", key)

      # Flip a byte in the ciphertext
      <<head::binary-20, byte, rest::binary>> = ciphertext
      tampered = <<head::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>

      assert :error = Encryption.decrypt(tampered, key)
    end
  end
end
