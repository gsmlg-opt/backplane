defmodule Backplane.McpProtocol.Id do
  @moduledoc """
  Helpers for MCP request IDs, progress tokens, and opaque session IDs.
  """

  @random_bytes 8
  @timestamp_bits 64

  @spec generate() :: String.t()
  def generate do
    timestamp = System.system_time(:nanosecond)
    random = :crypto.strong_rand_bytes(@random_bytes)

    <<timestamp::unsigned-big-integer-size(@timestamp_bits), random::binary>>
    |> Base.url_encode64()
  end

  @spec generate_request_id() :: String.t()
  def generate_request_id, do: "req_" <> generate()

  @spec generate_progress_token() :: String.t()
  def generate_progress_token, do: "progress_" <> generate()

  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id) do
    case Base.url_decode64(id) do
      {:ok,
       <<_timestamp::unsigned-big-integer-size(@timestamp_bits),
         _random::binary-size(@random_bytes)>>} ->
        true

      _other ->
        false
    end
  end

  def valid?(_id), do: false

  @spec valid_request_id?(term()) :: boolean()
  def valid_request_id?("req_" <> id), do: valid?(id)
  def valid_request_id?(_id), do: false

  @spec valid_progress_token?(term()) :: boolean()
  def valid_progress_token?("progress_" <> token), do: valid?(token)
  def valid_progress_token?(_token), do: false

  @spec timestamp_from_id(term()) :: integer() | nil
  def timestamp_from_id(id) when is_binary(id) do
    with {:ok,
          <<timestamp::unsigned-big-integer-size(@timestamp_bits),
            _random::binary-size(@random_bytes)>>} <-
           Base.url_decode64(id) do
      timestamp
    else
      _other -> nil
    end
  end

  def timestamp_from_id(_id), do: nil
end
