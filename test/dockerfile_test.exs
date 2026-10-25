ExUnit.start()

defmodule Backplane.DockerfileTest do
  use ExUnit.Case, async: true

  test "copies every umbrella app manifest before production deps are fetched" do
    dockerfile = File.read!(Path.expand("../Dockerfile", __DIR__))

    required_manifests =
      Path.wildcard(Path.expand("../apps/*/mix.exs", __DIR__))
      |> Enum.map(&Path.relative_to(&1, Path.expand("..", __DIR__)))
      |> Enum.reject(&ignored_app_manifest?/1)

    assert required_manifests != []

    for stage <- ["web-assets-builder", "builder"] do
      [dependency_stage, _rest] =
        dockerfile |> stage(stage) |> String.split(~r/^RUN mix deps\.get\b/m, parts: 2)

      for manifest <- required_manifests do
        assert dependency_stage =~ manifest,
               "expected #{manifest} to be copied before mix deps.get in #{stage}"
      end
    end
  end

  test "isolates native assets on Ubuntu 26 while preserving backend and runtime baselines" do
    dockerfile = File.read!(Path.expand("../Dockerfile", __DIR__))
    assets = stage(dockerfile, "web-assets-builder")
    builder = stage(dockerfile, "builder")
    runtime = stage(dockerfile, "runtime")

    assert assets =~ ~r/^FROM --platform=\$BUILDPLATFORM ubuntu:26\.04@sha256:[a-f0-9]{64}/
    assert stage(dockerfile, "beam-tools") =~ "--platform=$BUILDPLATFORM ${ELIXIR_IMAGE}"
    assert assets =~ "COPY --from=beam-tools /usr/local /usr/local"
    assert assets =~ "DUSKMOON_NATIVE_MODE=precompiled"
    refute assets =~ ~r/\b(cargo|rustc)\b/
    assert assets =~ "erlang:system_info(otp_release)"
    assert assets =~ "RUN mix assets.deploy"
    assert assets =~ ~s(--export . /web-assets "${VCS_REF}" "${VERSION}")

    assert dockerfile =~
             ~r/ARG ELIXIR_IMAGE=hexpm\/elixir:1\.18\.4-erlang-28\.0\.2-debian-bookworm-[^\n]+@sha256:[a-f0-9]{64}/

    assert builder =~ "FROM ${ELIXIR_IMAGE} AS builder"
    refute builder =~ "mix assets.deploy"
    refute builder =~ "mix npm.install"

    transfers = Regex.scan(~r/^COPY --from=web-assets-builder (.+)$/m, builder)
    assert length(transfers) == 2

    for app <- ~w(backplane_api backplane_admin) do
      assert builder =~
               "COPY --from=web-assets-builder /web-assets/apps/#{app}/priv/static ./apps/#{app}/priv/static"
    end

    assert runtime =~ "FROM ${DEBIAN_IMAGE} AS runtime"
    assert dockerfile =~ "ARG DEBIAN_IMAGE=debian:bookworm-slim"
    refute runtime =~ "web-assets-builder"
    assert stage(dockerfile, "web-assets") =~ "FROM scratch AS web-assets"
  end

  defp stage(dockerfile, name) do
    dockerfile
    |> String.split(~r/(?=^FROM )/m)
    |> Enum.find(fn stage ->
      stage |> String.split("\n") |> hd() |> String.ends_with?(" AS #{name}")
    end)
  end

  test "builds both web profiles through the guarded umbrella asset task" do
    dockerfile = File.read!(Path.expand("../Dockerfile", __DIR__))

    assert dockerfile =~ "RUN mix assets.deploy"
    refute dockerfile =~ ~s(mix "do" --app backplane_api assets.deploy)
    refute dockerfile =~ ~s(mix "do" --app backplane_admin assets.deploy)

    assert dockerfile =~
             "elixir -pa _build/prod/lib/jason/ebin scripts/verify_web_assets.exs"
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
