ExUnit.start()

defmodule Backplane.DockerfileTest do
  use ExUnit.Case, async: true

  test "builds and probes the optional target-native PTY helper before Linux assembly" do
    dockerfile = File.read!(Path.expand("../Dockerfile", __DIR__))
    builder = stage(dockerfile, "builder")
    [before_release, _] = String.split(builder, "RUN mix release backplane", parts: 2)
    assert before_release =~ "RUN mix backplane.pty.build"

    assert builder =~
             ~s(backplane_agent_runtime-${VERSION}/priv/bin/backplane-local-command-pty" --probe)

    refute stage(dockerfile, "web-assets-builder") =~ "mix backplane.pty.build"
  end

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

  test "normalizes source and plugin versions before compiling either Docker stage" do
    dockerfile = File.read!(Path.expand("../Dockerfile", __DIR__))
    normalize = ~s(RUN bash scripts/set-version.sh "${VERSION}" all)

    for {name, compile} <- [
          {"web-assets-builder", "RUN mix assets.deploy"},
          {"builder", "RUN mix release backplane"}
        ] do
      body = stage(dockerfile, name)
      assert body =~ normalize
      {copy_at, _} = :binary.match(body, "COPY . .")
      {normalize_at, _} = :binary.match(body, normalize)
      {compile_at, _} = :binary.match(body, compile)
      assert copy_at < normalize_at and normalize_at < compile_at

      directory = docker_version_fixture()

      {output, status} =
        System.cmd("sh", ["-c", String.replace_prefix(normalize, "RUN ", "")],
          cd: directory,
          env: [{"VERSION", "9.8.7"}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      refute File.exists?(Path.join(directory, "apps/backplane_host_agent"))

      for path <- ["mix.exs" | Path.wildcard("apps/*/mix.exs", match_dot: true)] do
        unless ignored_app_manifest?(path) do
          assert File.read!(Path.join(directory, path)) =~
                   ~r/(?:@version\s+|version:\s*)"9\.8\.7"/
        end
      end

      for path <- Path.wildcard(Path.join(directory, "integrations/memory/**/*.{yaml,json}")) do
        assert File.read!(path) =~ ~r/version[" :]++"?9\.8\.7/
      end
    end
  end

  test "Docker verifies assembled app versions without starting the release" do
    dockerfile = File.read!(Path.expand("../Dockerfile", __DIR__))
    builder = stage(dockerfile, "builder")

    assert [_, verify] =
             Regex.run(
               ~r/^RUN <<'VERIFY_RELEASE_VERSION'\n(.*?)\nVERIFY_RELEASE_VERSION$/ms,
               builder
             )

    refute verify =~ "bin/backplane"
    directory = docker_version_fixture()

    for {app, version} <- [{:backplane, "9.8.7"}, {:backplane_admin, "9.8.7"}] do
      write_app_spec(directory, app, version)
    end

    {output, status} = verify_docker_versions(verify, directory)
    assert status == 0, output

    write_app_spec(directory, :backplane_admin, "1.10.38")
    {output, status} = verify_docker_versions(verify, directory)
    assert status != 0
    assert output =~ "assembled application version mismatch"

    File.rm_rf!(Path.join(directory, "_build/prod/rel/backplane/lib"))
    {output, status} = verify_docker_versions(verify, directory)
    assert status != 0
    assert output =~ "assembled Backplane applications are missing"
  end

  defp docker_version_fixture do
    directory =
      Path.join(
        System.tmp_dir!(),
        "backplane-docker-version-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(directory) end)

    files =
      ["mix.exs", "scripts/set-version.sh"] ++
        Path.wildcard("apps/*/mix.exs") ++
        ~w(apps/backplane_mcp_protocol/README.md apps/backplane_mcp_protocol/pages/introduction.md apps/backplane_mcp_protocol/pages/building-a-server.md) ++
        ~w(integrations/memory/hermes/plugin.yaml integrations/memory/openclaw/plugin.yaml integrations/memory/openclaw/package.json integrations/memory/openclaw/openclaw.plugin.json)

    for path <- files, not ignored_app_manifest?(path) do
      destination = Path.join(directory, path)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(path, destination)
    end

    directory
  end

  defp write_app_spec(root, app, version) do
    path =
      Path.join([root, "_build/prod/rel/backplane/lib", "#{app}-9.8.7", "ebin", "#{app}.app"])

    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      :io_lib.format(~c"~p.~n", [{:application, app, [vsn: String.to_charlist(version)]}])
    )
  end

  defp verify_docker_versions(script, directory) do
    System.cmd("sh", ["-c", script],
      cd: directory,
      env: [{"VERSION", "9.8.7"}],
      stderr_to_stdout: true
    )
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
