ExUnit.start()

Code.require_file("../scripts/verify_web_assets.ex", __DIR__)

defmodule Backplane.WebAssetsTest do
  use ExUnit.Case, async: true

  @revision String.duplicate("a", 40)

  setup do
    root = Path.join(System.tmp_dir!(), "backplane-static-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    consumer = Path.join(root, "consumer")
    artifact = Path.join(root, "artifact")

    for directory <- [source, consumer] do
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "mix.lock"), "same locked dependencies")
    end

    for app <- ~w(backplane_api backplane_admin) do
      write_asset_tree(Path.join([source, "apps", app, "priv", "static"]))
    end

    on_exit(fn -> File.rm_rf!(root) end)
    %{source: source, consumer: consumer, artifact: artifact}
  end

  test "exports and consumes both complete static trees with immutable provenance", context do
    %{source: source, consumer: consumer, artifact: artifact} = context
    File.mkdir_p!(Path.join(source, "_build/prod"))
    File.write!(Path.join(source, "_build/prod/must-not-transfer.beam"), "compiled")
    File.write!(Path.join(source, "apps/backplane_api/priv/static/favicon.ico"), "icon")

    assert :ok = export_assets(context)
    refute File.exists?(Path.join(artifact, "_build"))
    refute File.exists?(Path.join(artifact, "mix.lock"))

    manifest = artifact |> Path.join("web-assets.json") |> File.read!() |> Jason.decode!()
    assert manifest["source_revision"] == @revision
    assert manifest["version"] == "9.8.7"
    assert map_size(manifest["files"]) == 15

    assert :ok = import_assets(context)
    assert :ok = Backplane.VerifyWebAssets.run(["--source", consumer])
    assert File.read!(Path.join(consumer, "apps/backplane_api/priv/static/favicon.ico")) == "icon"
  end

  test "rejects mismatched revision, version, lockfile and modified contents before import",
       context do
    assert :ok = export_assets(context)

    for {revision, version} <- [{String.duplicate("b", 40), "9.8.7"}, {@revision, "9.8.8"}] do
      assert_raise RuntimeError, ~r/provenance does not match/, fn ->
        Backplane.VerifyWebAssets.run([
          "--import",
          context.artifact,
          context.consumer,
          revision,
          version
        ])
      end
    end

    File.write!(Path.join(context.consumer, "mix.lock"), "different dependencies")
    assert_raise RuntimeError, ~r/provenance does not match/, fn -> import_assets(context) end
    File.cp!(Path.join(context.source, "mix.lock"), Path.join(context.consumer, "mix.lock"))

    File.write!(
      Path.join(context.artifact, "apps/backplane_api/priv/static/assets/js/app-built.js"),
      "changed"
    )

    assert_raise RuntimeError, ~r/contents do not match/, fn -> import_assets(context) end
    refute File.exists?(Path.join(context.consumer, "apps"))
  end

  test "rejects native code and symlinks even inside static directories", context do
    path = Path.join(context.source, "apps/backplane_api/priv/static/disguised.js")

    for content <- [<<0x7F, "ELF", 1>>, <<"FOR1", 0, 0, 0, 4, "BEAM">>] do
      File.write!(path, content)

      assert_raise RuntimeError, ~r/runtime or native file is forbidden/, fn ->
        export_assets(context)
      end

      refute File.exists?(context.artifact)
    end

    File.rm!(path)
    File.ln_s!(Path.join(context.source, "mix.lock"), path)

    assert_raise RuntimeError, ~r/only regular files and directories/, fn ->
      export_assets(context)
    end
  end

  test "rejects unexpected artifact paths before changing the consumer", context do
    assert :ok = export_assets(context)
    File.mkdir!(Path.join(context.artifact, "deps"))
    assert_raise RuntimeError, ~r/unexpected path.*deps/, fn -> import_assets(context) end
    refute File.exists?(Path.join(context.consumer, "apps"))
  end

  test "packaged releases reject build-only native asset dependencies", context do
    File.mkdir_p!(Path.join(context.consumer, "lib/duskmoon_vize-10.0.6"))

    assert_raise RuntimeError, ~r/build-only native asset tooling.*duskmoon_vize/, fn ->
      Backplane.VerifyWebAssets.run(["--release", context.consumer])
    end
  end

  test "release verification requires both apps and their served logical assets" do
    root =
      Path.join(System.tmp_dir!(), "backplane-web-assets-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    for app <- ~w(backplane_api backplane_admin) do
      static = Path.join([root, "lib", "#{app}-0.10.0", "priv", "static"])
      write_asset_tree(static)
    end

    assert :ok = Backplane.VerifyWebAssets.run(["--release", root])

    missing =
      Path.join([
        root,
        "lib",
        "backplane_admin-0.10.0",
        "priv",
        "static",
        "assets",
        "css",
        "app-built-digest.css"
      ])

    File.rm!(missing)

    assert_raise RuntimeError,
                 ~r/required web asset is missing or empty: .*backplane_admin.*assets\/css\/app-built-digest\.css/,
                 fn ->
                   Backplane.VerifyWebAssets.run(["--release", root])
                 end
  end

  defp write_asset_tree(static) do
    css_dir = Path.join([static, "assets", "css"])
    js_dir = Path.join([static, "assets", "js"])
    File.mkdir_p!(css_dir)
    File.mkdir_p!(js_dir)

    File.write!(Path.join(css_dir, "app-built.css"), "body {}")
    File.write!(Path.join(js_dir, "app-built.js"), "console.log('ok')")
    File.write!(Path.join(css_dir, "manifest.json"), manifest("app.css", "app-built.css"))
    File.write!(Path.join(js_dir, "manifest.json"), manifest("app.js", "app-built.js"))

    File.write!(Path.join(css_dir, "app-built-digest.css"), "body {}")
    File.write!(Path.join(js_dir, "app-built-digest.js"), "console.log('ok')")

    File.write!(
      Path.join(static, "cache_manifest.json"),
      Jason.encode!(%{
        "latest" => %{
          "assets/css/app-built.css" => "assets/css/app-built-digest.css",
          "assets/js/app-built.js" => "assets/js/app-built-digest.js"
        }
      })
    )
  end

  defp manifest(logical_name, output) do
    Jason.encode!(%{"entries" => %{logical_name => %{"file" => output}}})
  end

  defp export_assets(context) do
    Backplane.VerifyWebAssets.run([
      "--export",
      context.source,
      context.artifact,
      @revision,
      "9.8.7"
    ])
  end

  defp import_assets(context) do
    Backplane.VerifyWebAssets.run([
      "--import",
      context.artifact,
      context.consumer,
      @revision,
      "9.8.7"
    ])
  end
end
