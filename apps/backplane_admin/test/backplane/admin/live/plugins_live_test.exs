defmodule Backplane.Admin.PluginsLiveTest do
  use Backplane.Admin.LiveCase, async: false
  alias Backplane.Plugins
  alias Backplane.PluginProtocol.Archive

  defp package(content \\ "original") do
    %{
      "plugin.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
          "name" => "ui-plugin"
        }),
      "assets/data.txt" => content
    }
  end

  defp release do
    {:ok, release} = Plugins.import_files(package())
    release
  end

  test "Plugins navigation shows complete catalog and independent management sections", %{
    conn: conn
  } do
    release = release()
    {:ok, _view, html} = live(conn, "/plugins")
    assert html =~ "local/ui-plugin"
    assert html =~ "plugin-upload-form"
    assert html =~ "plugin-compose-form"
    assert html =~ "/plugins/sources"
    assert html =~ "/plugins/releases"
    assert html =~ "/plugins/distribution"
    assert html =~ "/plugins/#{release.plugin_id}"
    refute html =~ "#{release.artifact}"
  end

  test "uploads a full archive as a candidate without publishing it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/plugins")
    {:ok, bytes} = Archive.pack(package())

    upload =
      file_input(view, "#plugin-upload-form", :archive, [
        %{name: "plugin.tar.gz", content: bytes, type: "application/gzip"}
      ])

    assert render_upload(upload, "plugin.tar.gz") =~ "plugin.tar.gz"

    view
    |> form("#plugin-upload-form", %{"upload" => %{"publisher" => "team"}})
    |> render_submit()

    assert render(view) =~ "team/ui-plugin"
    assert Plugins.catalog().data == []
    [plugin] = Plugins.list_plugins()
    [release] = Plugins.list_releases(plugin.id)
    assert {:ok, files} = Archive.unpack(release.artifact)
    assert files["assets/data.txt"] == "original"
  end

  test "composes a candidate with valid default MCP declarations", %{conn: conn} do
    {:ok, view, _} = live(conn, "/plugins")
    manifest = package()["plugin.json"]

    view
    |> form("#plugin-compose-form", %{
      "compose" => %{
        "publisher" => "composer",
        "manifest" => manifest
      }
    })
    |> render_submit()

    assert render(view) =~ "composer/ui-plugin"
    assert Plugins.catalog().data == []
    [plugin] = Plugins.list_plugins()
    [release] = Plugins.list_releases(plugin.id)
    refute Enum.any?(release.diagnostics, &(&1["code"] == "invalid_mcp_config"))
    assert {:ok, files} = Archive.unpack(release.artifact)

    assert Jason.decode!(files["mcp.json"]) == %{
             "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
             "mcpServers" => %{}
           }
  end

  test "source CRUD preserves policies and reports asynchronous sync failure", %{conn: conn} do
    {:ok, view, _} = live(conn, "/plugins/sources")

    view
    |> form("#plugin-source-form", %{
      "source" => %{
        "name" => "Example source",
        "url" => "invalid-source",
        "ref" => "main",
        "kind" => "plugin",
        "interval_seconds" => "600",
        "enabled" => "false",
        "auto_publish" => "false"
      }
    })
    |> render_submit()

    [source] = Plugins.list_sources()
    assert source.interval_seconds == 600
    refute source.enabled
    view |> element("#plugin-source-#{source.id} [phx-click=sync-source]") |> render_click()
    assert render_async(view) =~ "invalid_github_url"
    assert Plugins.get_source(source.id).status == "failed"
    view |> element("#plugin-source-#{source.id} [phx-click=edit-source]") |> render_click()

    view
    |> form("#plugin-source-form", %{"source" => %{"name" => "Renamed source"}})
    |> render_submit()

    assert Plugins.get_source(source.id).name == "Renamed source"
    view |> element("#plugin-source-#{source.id} [phx-click=delete-source]") |> render_click()
    assert Plugins.list_sources() == []
  end

  test "publishes a candidate and rolls channel selection back without deleting releases", %{
    conn: conn
  } do
    first = release()
    {:ok, second} = Plugins.import_files(package("updated"))
    {:ok, view, _} = live(conn, "/plugins/releases")
    view |> form("#publish-#{first.id}") |> render_submit()
    assert {:ok, selected} = Plugins.resolve(first.plugin_id)
    assert selected.release_id == first.id
    view |> form("#publish-#{second.id}") |> render_submit()
    assert {:ok, selected} = Plugins.resolve(first.plugin_id)
    assert selected.release_id == second.id
    view |> form("#publish-#{first.id}") |> render_submit()
    assert {:ok, selected} = Plugins.resolve(first.plugin_id)
    assert selected.release_id == first.id
    assert {:ok, _} = Plugins.artifact(first.plugin_id, second.id)
  end

  test "release history identifies each plugin and links to its details", %{conn: conn} do
    first = release()
    {:ok, second} = Plugins.import_files(package(), %{publisher: "another"})
    {:ok, view, _} = live(conn, "/plugins/releases")

    assert has_element?(
             view,
             "#plugin-release-#{first.id} a[href='/plugins/#{first.plugin_id}']",
             "local/ui-plugin"
           )

    assert has_element?(
             view,
             "#plugin-release-#{second.id} a[href='/plugins/#{second.plugin_id}']",
             "another/ui-plugin"
           )
  end

  test "release history separates package validation, client support and actual reports", %{
    conn: conn
  } do
    {:ok, release} = Plugins.import_files(Map.put(package(), "mcp.json", "{}"))
    {:ok, _} = Plugins.publish_release(release.id)
    {:ok, installation} = Plugins.set_desired("consumer:reported", release.plugin_id, release.id)

    {:ok, _} =
      Plugins.report_installation(installation.id, %{
        actual_release_id: release.id,
        status: "partial",
        components: %{"skill" => "ready", "mcp" => "authentication_required"}
      })

    {:ok, view, _} = live(conn, "/plugins/releases")
    assert has_element?(view, "#plugin-validation-#{release.id}", "invalid_mcp_config")
    assert has_element?(view, "#plugin-client-support", "Portable skills and MCP supported")

    assert has_element?(
             view,
             "#plugin-client-support",
             "Proprietary extensions are not implemented"
           )

    assert has_element?(
             view,
             "#plugin-client-support",
             "support for all extensions is not established"
           )

    assert has_element?(view, "#plugin-client-support", "sample skill and stdio MCP verified")
    assert has_element?(view, "#plugin-client-support", "Product integration pending")
    assert has_element?(view, "#plugin-actual-state-#{release.id}", "consumer:reported")
    assert has_element?(view, "#plugin-actual-state-#{release.id}", "authentication_required")
    assert has_element?(view, "#plugin-release-#{release.id} details", "diagnostics (JSON)")
    assert has_element?(view, "#plugin-release-#{release.id} details", "invalid_mcp_config")
  end

  test "sets desired installation and shows actual state reported by consumer", %{conn: conn} do
    release = release()
    {:ok, _} = Plugins.publish_release(release.id)
    {:ok, view, _} = live(conn, "/plugins/distribution")

    view
    |> form("#plugin-desired-form", %{
      "installation" => %{
        "target" => "sigma:ui",
        "plugin_id" => release.plugin_id,
        "release_id" => release.id,
        "enabled" => "true"
      }
    })
    |> render_submit()

    [installation] = Plugins.list_installations()
    assert installation.actual_release_id == nil

    {:ok, _} =
      Plugins.report_installation(installation.id, %{
        actual_release_id: release.id,
        actual_enabled: false,
        status: "partial",
        components: %{"example" => "authentication_required"}
      })

    html = render_patch(view, "/plugins/distribution")
    assert html =~ "sigma:ui"
    assert html =~ "authentication_required"
    assert html =~ "partial"
    assert html =~ "plugin-git-form"
  end

  test "exports full selected release through explicit local distribution action", %{conn: conn} do
    release = release()
    {:ok, _} = Plugins.publish_release(release.id)
    directory = Path.join(System.tmp_dir!(), "plugin-ui-export-" <> Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, view, _} = live(conn, "/plugins/distribution")

    view
    |> form("#plugin-export-form", %{
      "export" => %{"directory" => directory, "channel" => "stable", "name" => "ui-marketplace"}
    })
    |> render_submit()

    assert render_async(view) =~ release.artifact_digest

    assert File.read!(Path.join([directory, "plugins", release.plugin_id, "assets/data.txt"])) ==
             "original"

    assert File.exists?(Path.join(directory, ".agents/plugins/marketplace.json"))
  end

  test "Codex duplicate names explain explicit scope selection", %{conn: conn} do
    first = release()
    {:ok, other} = Plugins.import_files(package("other"), %{publisher: "other"})
    {:ok, _} = Plugins.publish_release(first.id)
    {:ok, _} = Plugins.publish_release(other.id)
    directory = Path.join(System.tmp_dir!(), "plugin-ui-scope-" <> Ecto.UUID.generate())
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, view, _} = live(conn, "/plugins/distribution")

    view
    |> form("#plugin-export-form", %{"export" => %{"directory" => directory}})
    |> render_submit()

    assert render_async(view) =~ "Select one publisher for each name"

    view
    |> form("#plugin-export-form", %{
      "export" => %{"directory" => directory, "plugin_ids" => [first.plugin_id]}
    })
    |> render_submit()

    assert render_async(view) =~ first.artifact_digest

    manifest =
      File.read!(Path.join(directory, ".agents/plugins/marketplace.json")) |> Jason.decode!()

    assert [%{"name" => "ui-plugin"}] = manifest["plugins"]
  end
end
