ExUnit.start()

Code.require_file("../scripts/verify_web_assets.ex", __DIR__)

defmodule Backplane.WebAssetsTest do
  use ExUnit.Case, async: true

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
end
