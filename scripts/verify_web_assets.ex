defmodule Backplane.VerifyWebAssets do
  @moduledoc false

  @apps ~w(backplane_api backplane_admin)

  def run(["--source", root]) do
    verify_apps(fn app -> Path.join([root, "apps", app, "priv", "static"]) end)
  end

  def run(["--release", release_root]) do
    verify_apps(fn app -> release_static_root!(release_root, app) end)
  end

  def run(_args) do
    raise ArgumentError,
          "usage: elixir -pa PATH_TO_JASON_EBIN scripts/verify_web_assets.exs " <>
            "--source ROOT | --release RELEASE_ROOT"
  end

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
