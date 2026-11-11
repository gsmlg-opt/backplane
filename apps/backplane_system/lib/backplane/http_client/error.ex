defmodule Backplane.HTTPClient.Error do
  @moduledoc """
  A request that produced no usable response.

  `reason` is normalized from `HTTP.fetch/2`: transport failures keep their
  atom (`:timeout`, `:econnrefused`, `:closed`, ...); client-side failures use
  `:invalid_url`, `:conflicting_body_options`, `:response_too_large`,
  `{:invalid_json, error}` and `{:stream_down, reason}`.
  """

  defexception [:reason]

  @type t :: %__MODULE__{reason: term()}

  @impl true
  def message(%__MODULE__{reason: reason}), do: "HTTP request failed: #{inspect(reason)}"
end
