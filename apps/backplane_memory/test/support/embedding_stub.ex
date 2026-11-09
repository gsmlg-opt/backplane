defmodule Backplane.Memory.EmbeddingStub do
  @moduledoc "Test helper: Req plug stub serving deterministic 2560-dim vectors."

  @dims 2560

  @doc "Unit vector along axis `axis`, slightly perturbed by `eps`."
  def vector(axis, eps \\ 0.0) do
    for i <- 0..(@dims - 1), do: if(i == axis, do: 1.0, else: eps * 1.0)
  end

  @doc """
  Plug serving vectors: input text containing `axis:N` maps to `vector(N)`;
  anything else maps to axis 0.
  """
  def plug(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"input" => inputs} = Jason.decode!(body)

    data =
      inputs
      |> Enum.with_index()
      |> Enum.map(fn {text, index} ->
        axis =
          case Regex.run(~r/axis:(\d+)/, text) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        %{"index" => index, "embedding" => vector(axis)}
      end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => data}))
  end

  def error_plug(conn), do: Plug.Conn.send_resp(conn, 500, "boom")

  def short_plug(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"input" => inputs} = Jason.decode!(body)

    data =
      for {_t, i} <- Enum.with_index(inputs),
          do: %{"index" => i, "embedding" => [0.1, 0.2]}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => data}))
  end
end
