defmodule Backplane.Oauth.SecureToken do
  @moduledoc false

  @behaviour Backplane.Oauth.TokenGenerator

  @alphanum_chars "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  @token_length 86

  @impl Backplane.Oauth.TokenGenerator
  def generate(_, _) do
    generate()
  end

  def generate do
    random_string(@alphanum_chars, @token_length)
  end

  @impl Backplane.Oauth.TokenGenerator
  def secret(_) do
    generate()
  end

  defp random_string(characters, length) do
    character_count = byte_size(characters)
    unbiased_limit = div(256, character_count) * character_count

    characters
    |> random_characters(length, character_count, unbiased_limit, [])
    |> IO.iodata_to_binary()
  end

  defp random_characters(_characters, 0, _character_count, _unbiased_limit, acc) do
    Enum.reverse(acc)
  end

  defp random_characters(characters, length, character_count, unbiased_limit, acc) do
    bytes = :crypto.strong_rand_bytes(length * 2)

    {remaining, acc} =
      Enum.reduce_while(:binary.bin_to_list(bytes), {length, acc}, fn
        _byte, {0, acc} ->
          {:halt, {0, acc}}

        byte, {remaining, acc} when byte < unbiased_limit ->
          character = binary_part(characters, rem(byte, character_count), 1)
          {:cont, {remaining - 1, [character | acc]}}

        _byte, state ->
          {:cont, state}
      end)

    random_characters(characters, remaining, character_count, unbiased_limit, acc)
  end
end
