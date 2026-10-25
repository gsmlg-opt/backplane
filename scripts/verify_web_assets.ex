defmodule Backplane.VerifyWebAssets do
  @moduledoc false

  @apps ~w(backplane_api backplane_admin)
  @artifact_manifest "web-assets.json"

  def run(["--source", root]) do
    verify_apps(fn app -> Path.join([root, "apps", app, "priv", "static"]) end)
  end

  def run(["--release", release_root]) do
    for app <-
          ~w(duskmoon_bundler duskmoon_vize duskmoon_oxc duskmoon_oxide duskmoon_quickbeam duskmoon_npm) do
      unless Path.wildcard(Path.join([release_root, "lib", "#{app}-*"])) == [] do
        raise "build-only native asset tooling is forbidden in the release: #{app}"
      end
    end

    verify_apps(fn app -> release_static_root!(release_root, app) end)
  end

  def run(["--export", root, artifact, revision, version]) do
    run(["--source", root])

    if File.exists?(artifact), do: raise("asset export destination already exists: #{artifact}")

    files = static_files!(root)
    manifest = provenance(root, revision, version) |> Map.put("files", files)

    for app <- @apps do
      path = static_path(app)
      File.mkdir_p!(Path.dirname(Path.join(artifact, path)))
      File.cp_r!(Path.join(root, path), Path.join(artifact, path))
    end

    File.write!(Path.join(artifact, @artifact_manifest), Jason.encode!(manifest))
    :ok
  end

  def run(["--import", artifact, root, revision, version]) do
    manifest = read_json!(Path.join(artifact, @artifact_manifest))
    expected = provenance(root, revision, version)

    unless Map.take(manifest, Map.keys(expected)) == expected do
      raise "web asset provenance does not match the consuming source, version and lockfile"
    end

    files = artifact_files!(artifact, "")

    unless Map.delete(files, @artifact_manifest) == manifest["files"] do
      raise "web asset artifact contents do not match their checksums"
    end

    run(["--source", artifact])

    for app <- @apps do
      path = static_path(app)
      destination = Path.join(root, path)
      File.rm_rf!(destination)
      File.mkdir_p!(Path.dirname(destination))
      File.cp_r!(Path.join(artifact, path), destination)
    end

    run(["--source", root])
  end

  def run(_args) do
    raise ArgumentError,
          "usage: elixir -pa PATH_TO_JASON_EBIN scripts/verify_web_assets.exs " <>
            "--source ROOT | --release RELEASE_ROOT | " <>
            "--export ROOT ARTIFACT REVISION VERSION | --import ARTIFACT ROOT REVISION VERSION"
  end

  defp provenance(root, revision, version) do
    unless Regex.match?(~r/\A[0-9a-f]{40}\z/, revision) and version != "" do
      raise "web asset provenance requires a full source SHA and release version"
    end

    %{
      "source_revision" => revision,
      "version" => version,
      "mix_lock_sha256" => checksum(Path.join(root, "mix.lock"))
    }
  end

  defp static_path(app), do: Path.join(["apps", app, "priv", "static"])

  defp static_files!(root) do
    Enum.reduce(@apps, %{}, fn app, files ->
      Map.merge(files, artifact_files!(root, static_path(app)))
    end)
  end

  defp artifact_files!(root, relative) do
    path = Path.join(root, relative)

    unless allowed_artifact_path?(relative) do
      raise "unexpected path in web asset artifact: #{relative}"
    end

    case File.lstat!(path).type do
      :directory ->
        path
        |> File.ls!()
        |> Enum.reduce(%{}, fn child, files ->
          Map.merge(files, artifact_files!(root, Path.join(relative, child)))
        end)

      :regular ->
        reject_runtime_file!(path)
        %{relative => checksum(path)}

      _ ->
        raise "web asset artifact must contain only regular files and directories: #{relative}"
    end
  end

  defp allowed_artifact_path?(relative) do
    relative in ["", @artifact_manifest, "apps"] or
      Enum.any?(@apps, fn app ->
        relative in ["apps/#{app}", "apps/#{app}/priv", static_path(app)] or
          String.starts_with?(relative, static_path(app) <> "/")
      end)
  end

  defp reject_runtime_file!(path) do
    content = File.read!(path)

    native_magic? =
      Enum.any?(
        [
          <<0x7F, 0x45, 0x4C, 0x46>>,
          <<0xFE, 0xED, 0xFA, 0xCE>>,
          <<0xFE, 0xED, 0xFA, 0xCF>>,
          <<0xCE, 0xFA, 0xED, 0xFE>>,
          <<0xCF, 0xFA, 0xED, 0xFE>>,
          <<0xCA, 0xFE, 0xBA, 0xBE>>
        ],
        &String.starts_with?(content, &1)
      )

    beam? = match?(<<"FOR1", _::binary-size(4), "BEAM", _::binary>>, content)

    if native_magic? or beam? or Regex.match?(~r/\.(beam|so(\.\d+)*|dylib|dll|a|o)$/, path) do
      raise "runtime or native file is forbidden in web asset artifact: #{path}"
    end
  end

  defp checksum(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp verify_apps(static_root) do
    Enum.each(@apps, fn app ->
      root = static_root.(app)
      css_path = verify_bundler_manifest!(root, "css", "app.css")
      js_path = verify_bundler_manifest!(root, "js", "app.js")
      verify_cache_manifest!(root, [css_path, js_path])
    end)

    :ok
  end

  defp release_static_root!(release_root, app) do
    matches = Path.wildcard(Path.join([release_root, "lib", "#{app}-*", "priv", "static"]))

    case matches do
      [root] -> root
      [] -> raise "packaged assets missing for #{app} under #{release_root}"
      _ -> raise "multiple packaged asset roots found for #{app} under #{release_root}"
    end
  end

  defp verify_bundler_manifest!(root, kind, logical_name) do
    manifest_path = Path.join([root, "assets", kind, "manifest.json"])
    manifest = read_json!(manifest_path)

    file =
      get_in(manifest, ["entries", logical_name, "file"]) ||
        raise "#{manifest_path} does not contain an output for #{logical_name}"

    asset_path = Path.join(["assets", kind, file])
    ensure_nonempty!(Path.join(root, asset_path))
    asset_path
  end

  defp verify_cache_manifest!(root, asset_paths) do
    manifest_path = Path.join(root, "cache_manifest.json")
    manifest = read_json!(manifest_path)

    Enum.each(asset_paths, fn asset_path ->
      digest_path =
        get_in(manifest, ["latest", asset_path]) ||
          raise "#{manifest_path} does not contain #{asset_path}"

      ensure_nonempty!(Path.join(root, digest_path))
    end)
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  rescue
    error -> raise "cannot read asset manifest #{path}: #{Exception.message(error)}"
  end

  defp ensure_nonempty!(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 -> :ok
      _ -> raise "required web asset is missing or empty: #{path}"
    end
  end
end
