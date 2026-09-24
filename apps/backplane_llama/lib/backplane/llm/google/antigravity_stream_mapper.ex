defmodule Backplane.LLM.Google.AntigravityStreamMapper do
  @moduledoc false

  alias Backplane.AiProtocol.Antigravity.Google

  def init(status, _headers, opts) when status in 200..299,
    do: {:ok, {:translate, Google.stream_new(opts)}}

  def init(_status, _headers, _opts), do: {:ok, :passthrough}

  def feed(:passthrough, chunk), do: {:ok, :passthrough, [chunk]}

  def feed({:failed, state}, _chunk), do: {:ok, {:failed, state}, []}

  def feed({:translate, state}, chunk) do
    case Google.stream_feed(state, chunk) do
      {:ok, state, chunks} -> {:ok, {:translate, state}, chunks}
      {:error, error, state} -> {:error, error, {:failed, state}, [error_frame(error)]}
    end
  end

  def finish(:passthrough, _reason), do: {:ok, :passthrough, []}
  def finish({:failed, state}, _reason), do: {:ok, {:failed, state}, []}

  def finish({:translate, state}, reason) do
    case Google.stream_finish(state, reason) do
      {:ok, state, chunks} -> {:ok, {:translate, state}, chunks}
      {:error, error, state} -> {:error, error, {:failed, state}, [error_frame(error)]}
    end
  end

  defp error_frame(error) do
    body = %{"error" => %{"code" => 502, "message" => error.message, "status" => "UNAVAILABLE"}}
    "data: " <> Jason.encode!(body) <> "\n\n"
  end
end
