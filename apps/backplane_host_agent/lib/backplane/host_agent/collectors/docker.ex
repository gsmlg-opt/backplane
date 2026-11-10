defmodule Backplane.HostAgent.Collectors.Docker do
  @moduledoc """
  Snapshots running Docker containers via `docker ps`.

  Volatile fields (`Status`, e.g. "Up 3 hours") are never reported. A missing
  binary or failing command yields no snapshot rather than an empty one.
  """

  @behaviour Backplane.HostAgent.Collectors.Collector

  alias Backplane.HostAgent.Collectors.Collector

  @impl true
  def config_key, do: :docker

  @impl true
  def collect(_config, %{runner: runner}) do
    case runner.("docker", ["ps", "--format", "{{json .}}"], []) do
      {:ok, out} ->
        parsed =
          out |> Collector.sanitize() |> String.split("\n", trim: true) |> Enum.map(&parse_line/1)

        [
          %{
            collector: "docker",
            unit: "local",
            complete: Enum.all?(parsed, &match?({:ok, _}, &1)),
            items: for({:ok, item} <- parsed, do: item)
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp parse_line(line) do
    with {:ok, %{"Names" => name, "Image" => image, "State" => state} = row} <-
           Jason.decode(line),
         true <- is_binary(name) and is_binary(image) and is_binary(state) do
      {:ok, %{"name" => name, "image" => image, "state" => state, "ports" => ports(row["Ports"])}}
    else
      _ -> :error
    end
  end

  defp ports(value) when is_binary(value) and value != "" do
    value |> String.split(", ", trim: true) |> Enum.sort()
  end

  defp ports(_value), do: []
end
