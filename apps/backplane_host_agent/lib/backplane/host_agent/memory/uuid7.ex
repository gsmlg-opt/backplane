defmodule Backplane.HostAgent.Memory.UUID7 do
  @moduledoc """
  Generates local UUIDv7 identifiers for host-agent memory rows.
  """

  import Bitwise

  @timestamp_mask 0xFFFF_FFFF_FFFF
  @rand_a_mask 0x0FFF
  @rand_b_mask 0x3FFF_FFFF_FFFF_FFFF

  @doc "Returns a UUIDv7 string."
  def generate do
    timestamp_ms = System.system_time(:millisecond) &&& @timestamp_mask
    <<rand_a_raw::16>> = :crypto.strong_rand_bytes(2)
    <<rand_b_raw::64>> = :crypto.strong_rand_bytes(8)

    bytes =
      <<timestamp_ms::48, 7::4, rand_a_raw &&& @rand_a_mask::12, 2::2,
        rand_b_raw &&& @rand_b_mask::62>>

    format(bytes)
  end

  defp format(<<a::32, b::16, c::16, d::16, e::48>>) do
    [
      encode(<<a::32>>),
      encode(<<b::16>>),
      encode(<<c::16>>),
      encode(<<d::16>>),
      encode(<<e::48>>)
    ]
    |> Enum.join("-")
  end

  defp encode(bytes), do: Base.encode16(bytes, case: :lower)
end
