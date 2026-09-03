defmodule Backplane.Observability.Id do
  @moduledoc false

  @type id :: String.t()

  @doc "Generates a 128-bit opaque event identifier as lowercase hex."
  @spec event_id() :: id()
  def event_id, do: random_hex(16)

  @doc "Generates a trace identifier compatible with W3C trace context (32 hex chars)."
  @spec trace_id() :: id()
  def trace_id, do: random_hex(16)

  @doc "Generates a span identifier (16 hex chars)."
  @spec span_id() :: id()
  def span_id, do: random_hex(8)

  @doc "Generates a request identifier when Plug.RequestId is unavailable."
  @spec request_id() :: id()
  def request_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc false
  @spec generator() :: module()
  def generator do
    Application.get_env(:backplane_telemetry, :observability_id_generator, __MODULE__)
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes)
    |> Base.encode16(case: :lower)
  end
end
