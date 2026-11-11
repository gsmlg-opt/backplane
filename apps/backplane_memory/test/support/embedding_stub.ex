defmodule Backplane.Memory.EmbeddingStub do
  @moduledoc "Test helper: HTTP.Test fixtures serving deterministic 2560-dim vectors."

  @dims 2560

  @doc "Unit vector along axis `axis`, slightly perturbed by `eps`."
  def vector(axis, eps \\ 0.0) do
    for i <- 0..(@dims - 1), do: if(i == axis, do: 1.0, else: eps * 1.0)
  end

  @doc """
  Fixture serving vectors: input text containing `axis:N` maps to `vector(N)`;
  anything else maps to axis 0.
  """
  def plug(request) do
    data =
      request
      |> inputs()
      |> Enum.with_index()
      |> Enum.map(fn {text, index} ->
        axis =
          case Regex.run(~r/axis:(\d+)/, text) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        %{"index" => index, "embedding" => vector(axis)}
      end)

    HTTP.Test.json(%{"data" => data})
  end

  def error_plug(_request), do: HTTP.Test.response(500, "boom")

  def short_plug(request) do
    data =
      for {_t, i} <- Enum.with_index(inputs(request)),
          do: %{"index" => i, "embedding" => [0.1, 0.2]}

    HTTP.Test.json(%{"data" => data})
  end

  defp inputs(request) do
    %{"input" => inputs} = request.body |> IO.iodata_to_binary() |> Jason.decode!()
    inputs
  end
end
