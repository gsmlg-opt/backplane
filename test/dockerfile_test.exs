ExUnit.start()

defmodule Backplane.DockerfileTest do
  use ExUnit.Case, async: true

  test "copies every umbrella app manifest before production deps are fetched" do
    dockerfile = File.read!(Path.expand("../Dockerfile", __DIR__))

    dependency_stage =
      dockerfile |> String.split("RUN mix deps.get --only prod", parts: 2) |> hd()

    required_manifests =
      Path.wildcard(Path.expand("../apps/*/mix.exs", __DIR__))
      |> Enum.map(&Path.relative_to(&1, Path.expand("..", __DIR__)))
      |> Enum.reject(&ignored_app_manifest?/1)

    assert required_manifests != []

    for manifest <- required_manifests do
      assert dependency_stage =~ manifest,
             "expected #{manifest} to be copied before mix deps.get --only prod"
    end
  end

  defp ignored_app_manifest?(manifest) do
    ignored_paths =
      Path.expand("../.dockerignore", __DIR__)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> MapSet.new()

    manifest
    |> Path.dirname()
    |> then(&MapSet.member?(ignored_paths, &1))
  end
end
