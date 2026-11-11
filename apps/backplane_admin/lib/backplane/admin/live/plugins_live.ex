defmodule Backplane.Admin.PluginsLive do
  @moduledoc "Plugin candidates, immutable releases, sources and consumer distribution."
  use Backplane.Admin, :live_view
  import Ecto.Query
  alias Backplane.Plugins
  alias Backplane.Plugins.Source
  alias Backplane.Settings.Credentials

  @schema "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/plugins",
       plugins: [],
       releases: [],
       release_details: %{},
       channels: [],
       sources: [],
       installations: [],
       selected: nil,
       source_form: to_form(%{}, as: :source),
       editing_source: nil,
       skill_options: [],
       credentials: [],
       busy: [],
       export_result: nil
     )
     |> allow_upload(:archive,
       accept: :any,
       max_entries: 1,
       max_file_size: 50_000_000
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    path =
      case socket.assigns.live_action do
        :sources -> "/plugins/sources"
        :distribution -> "/plugins/distribution"
        :releases -> "/plugins/releases"
        _ -> "/plugins"
      end

    {:noreply,
     socket |> assign(current_path: path, selected: Plugins.get_plugin(params["id"])) |> reload()}
  end

  @impl true
  def handle_event("validate", _, socket), do: {:noreply, socket}

  def handle_event("upload", params, socket) do
    attrs = %{publisher: get_in(params, ["upload", "publisher"]) || "local"}

    results =
      consume_uploaded_entries(socket, :archive, fn %{path: path}, _ ->
        {:ok, File.read!(path) |> Plugins.import_archive(attrs)}
      end)

    case results do
      [{:ok, _}] ->
        {:noreply, socket |> put_flash(:info, dgettext("admin", "Plugin candidate imported")) |> reload()}

      _ ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Select a complete valid plugin archive"))}
    end
  end

  def handle_event("compose", %{"compose" => params}, socket) do
    with {:ok, manifest} <- Jason.decode(params["manifest"] || "{}"),
         {:ok, mcp} <- Jason.decode(params["mcp"] || "{}"),
         {:ok, selections} <- selections(params["skills"] || []),
         {:ok, _} <-
           Plugins.compose(manifest, selections, %{"mcp.json" => Jason.encode!(mcp)}, %{
             publisher: params["publisher"] || "local"
           }) do
      {:noreply,
       socket
       |> put_flash(:info, dgettext("admin", "Plugin candidate composed from fixed skill revisions"))
       |> reload()}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("errors", "Check manifest, MCP declarations and exact skill selections"))}
    end
  end

  def handle_event("publish", %{"release" => params}, socket) do
    finish(
      socket,
      Plugins.publish_release(params["id"], params["channel"] || "stable"),
      dgettext("admin", "Channel selected; existing releases remain available")
    )
  end

  def handle_event("edit-source", %{"id" => id}, socket) do
    case Plugins.get_source(id) do
      nil ->
        {:noreply, put_flash(socket, :error, dgettext("errors", "Source not found"))}

      source ->
        fields = ~w(name url ref path kind credential_name enabled auto_publish interval_seconds)a
        params = Map.new(fields, fn field -> {to_string(field), Map.get(source, field)} end)

        {:noreply,
         assign(socket, editing_source: source, source_form: to_form(params, as: :source))}
    end
  end

  def handle_event("cancel-source", _, socket), do: {:noreply, reset_source(socket)}

  def handle_event("save-source", %{"source" => attrs}, socket) do
    attrs =
      Map.take(
        attrs,
        ~w(name url ref path kind credential_name enabled auto_publish interval_seconds)
      )

    attrs =
      Map.update(attrs, "credential_name", nil, fn value ->
        if value == "", do: nil, else: value
      end)

    result =
      case socket.assigns.editing_source do
        %Source{} = source -> Plugins.update_source(source, attrs)
        nil -> Plugins.create_source(attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket |> reset_source() |> put_flash(:info, dgettext("admin", "Plugin source saved")) |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, source_form: to_form(changeset, as: :source))}
    end
  end

  def handle_event("delete-source", %{"id" => id}, socket) do
    result =
      case Plugins.get_source(id) do
        nil -> {:error, :not_found}
        source -> Plugins.delete_source(source)
      end

    finish(socket, result, dgettext("admin", "Source removed; published releases remain available"))
  end

  def handle_event("sync-source", %{"id" => id}, socket) do
    if id in socket.assigns.busy do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(busy: [id | socket.assigns.busy])
       |> start_async({:sync, id}, fn -> Plugins.sync_source(id) end)}
    end
  end

  def handle_event("desired", %{"installation" => params}, socket) do
    finish(
      socket,
      Plugins.set_desired(params["target"], params["plugin_id"], params["release_id"], %{
        enabled: params["enabled"] == "true"
      }),
      dgettext("admin", "Desired plugin state saved; consumers report actual installation separately")
    )
  end

  def handle_event("export", %{"export" => params}, socket) do
    opts = export_options(params)

    {:noreply,
     socket
     |> assign(export_result: nil)
     |> start_async(:export, fn -> Plugins.Codex.export(params["directory"], opts) end)}
  end

  def handle_event("publish-git", %{"git" => params}, socket) do
    # This explicit operator action is the only UI path that pushes to a remote repository.
    config = Map.take(params, ~w(url branch credential_name))
    opts = export_options(params)

    {:noreply,
     socket
     |> assign(export_result: nil)
     |> start_async(:publish_git, fn -> Plugins.Codex.publish_git(config, opts) end)}
  end

  @impl true
  def handle_async({:sync, id}, {:ok, {:ok, _}}, socket) do
    {:noreply,
     socket
     |> assign(busy: List.delete(socket.assigns.busy, id))
     |> put_flash(:info, dgettext("admin", "Source sync completed; inspect diagnostics for partial results"))
     |> reload()}
  end

  def handle_async({:sync, id}, _result, socket) do
    {:noreply,
     socket
     |> assign(busy: List.delete(socket.assigns.busy, id))
     |> put_flash(:error, dgettext("errors", "Source sync failed; prior published releases remain available"))
     |> reload()}
  end

  def handle_async(_name, {:ok, {:error, :duplicate_codex_plugin_name}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       dgettext("errors", "Codex requires unique plugin names. Select one publisher for each name in the export scope, or choose a channel with unique names.")
     )}
  end

  def handle_async(_name, {:ok, {:ok, result}}, socket),
    do: {:noreply, assign(socket, export_result: result)}

  def handle_async(_name, _result, socket),
    do:
      {:noreply,
       put_flash(
         socket,
         :error,
         dgettext("errors", "Distribution failed; check destination, repository and credential configuration")
       )}

  defp export_options(params) do
    opts = [channel: params["channel"] || "stable", name: params["name"] || "backplane"]

    case params["plugin_ids"] do
      ids when is_list(ids) and ids != [] -> Keyword.put(opts, :plugin_ids, ids)
      _ -> opts
    end
  end

  defp finish(socket, {:ok, _}, message),
    do: {:noreply, socket |> put_flash(:info, message) |> reload()}

  defp finish(socket, {:error, _}, _message),
    do:
      {:noreply,
       put_flash(socket, :error, dgettext("errors", "Operation failed; check the selected records and configuration"))}

  defp reset_source(socket),
    do: assign(socket, editing_source: nil, source_form: to_form(%{}, as: :source))

  defp selections(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, selections} ->
      case Jason.decode(value) do
        {:ok, selection} when is_map(selection) -> {:cont, {:ok, selections ++ [selection]}}
        _ -> {:halt, {:error, :invalid_selection}}
      end
    end)
  end

  defp reload(socket) do
    plugins = Plugins.list_plugins()
    selected = socket.assigns.selected

    releases =
      if selected,
        do: Plugins.list_releases(selected.id),
        else: Enum.flat_map(plugins, &Plugins.list_releases(&1.id))

    skills =
      Backplane.Repo.all(
        from r in Backplane.Skills.Revision,
          join: s in Backplane.Skills.Skill,
          on: s.id == r.skill_id,
          order_by: [s.slug, r.revision],
          select: {s, r}
      )

    options =
      Enum.map(skills, fn {skill, revision} ->
        {Jason.encode!(%{skill_id: skill.id, revision: revision.revision, name: skill.slug}),
         skill.slug <> " / " <> revision.revision}
      end)

    details = Map.new(releases, fn release -> {release.id, component_details(release)} end)

    assign(socket,
      plugins: plugins,
      releases: releases,
      release_details: details,
      channels: Plugins.list_channels(),
      sources: Plugins.list_sources(),
      installations: Plugins.list_installations(),
      skill_options: options,
      credentials: Enum.map(Credentials.list(), &{&1.name, &1.name})
    )
  end

  defp component_details(release) do
    with {:ok, files} <- Backplane.PluginProtocol.Archive.unpack(release.artifact),
         {:ok, package} <- Backplane.PluginProtocol.load(files) do
      %{
        skills: Enum.map(package.skills, &Map.take(&1, [:name, :path])),
        mcp_servers: Map.keys(package.mcp_servers),
        files: Enum.sort(Map.keys(files)),
        client_extensions:
          if(is_map(release.manifest["extensions"]),
            do: Map.keys(release.manifest["extensions"]),
            else: []
          )
      }
    else
      _ -> %{status: dgettext("errors", "Artifact validation failed")}
    end
  end

  defp release_label(release),
    do: (release.upstream_version || dgettext("admin", "No upstream version")) <> " / " <> release.id

  defp plugin_name(plugins, id) do
    case Enum.find(plugins, &(&1.id == id)) do
      nil -> id
      plugin -> plugin.identity
    end
  end

  defp manifest_example,
    do:
      Jason.encode!(
        %{"$schema" => @schema, "name" => "my-plugin", "description" => "Plugin description"},
        pretty: true
      )

  defp mcp_example,
    do:
      Jason.encode!(
        %{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
          "mcpServers" => %{}
        },
        pretty: true
      )

  defp compatibility_rows do
    [
      %{
        client: dgettext("admin", "Shared Runtime"),
        portable: dgettext("admin", "Portable skills and MCP supported"),
        extensions: dgettext("admin", "Proprietary extensions are not implemented"),
        evidence:
          dgettext(
            "admin",
            "Shared host implementation; component availability depends on the consumer environment"
          )
      },
      %{
        client: "Codex",
        portable: dgettext("admin", "Native client interprets the package"),
        extensions:
          dgettext(
            "admin",
            "Interpreted by the native client; support for all extensions is not established"
          ),
        evidence: dgettext("admin", "Codex 0.163.0 sample skill and stdio MCP verified")
      },
      %{
        client: "Sigma / Synapsis",
        portable: dgettext("admin", "Shared SDK and Runtime available"),
        extensions: dgettext("admin", "Product integration pending"),
        evidence: dgettext("admin", "Product integration and acceptance remain to be completed")
      }
    ]
  end

  defp actual_enablement_text(nil), do: dgettext("admin", "Enablement not reported")
  defp actual_enablement_text(true), do: dgettext("common", "Enabled")
  defp actual_enablement_text(false), do: dgettext("common", "Disabled")

  defp release_installations(installations, release_id),
    do:
      Enum.filter(
        installations,
        &(&1.actual_release_id == release_id or &1.desired_release_id == release_id)
      )

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 max-w-7xl mx-auto w-full min-w-0">
      <header>
        <h1 class="text-3xl font-bold">{dgettext("navigation", "Plugins")}</h1>
        <p class="text-on-surface-variant">{dgettext("admin", "Publish complete packages, synchronize fixed sources, and distribute selected releases.")}</p>
      </header>
      <div :if={@live_action in [:index, :show]} class="space-y-6">
        <.dm_card>
          <:title>{dgettext("admin", "Plugin catalog")}</:title>
          <p :if={@plugins == []} class="text-on-surface-variant">{dgettext("admin", "No plugins yet. Import a package or compose one from existing skills.")}</p>
          <.dm_table :if={@plugins != []} id="plugin-catalog" data={@plugins} hover zebra>
            <:col :let={plugin} label={dgettext("admin", "Identity")}><.dm_link navigate={~p"/plugins/#{plugin.id}"}>{plugin.identity}</.dm_link></:col>
            <:col :let={plugin} label={dgettext("admin", "Publisher")}>{plugin.publisher}</:col>
            <:col :let={plugin} label={dgettext("admin", "Origin")}>{if plugin.source_id, do: dgettext("admin", "Synchronized"), else: dgettext("admin", "Created locally")}</:col>
          </.dm_table>
        </.dm_card>
        <.dm_card>
          <:title>{dgettext("admin", "Import plugin archive")}</:title>
          <.form for={to_form(%{}, as: :upload)} id="plugin-upload-form" phx-submit="upload" phx-change="validate">
            <.dm_input name="upload[publisher]" label={dgettext("admin", "Publisher")} value="local" required />
            <label class="block my-4">{dgettext("admin", "Complete .tar.gz package (up to 50 MB)")}<.live_file_input upload={@uploads.archive} /></label>
            <p :for={entry <- @uploads.archive.entries}>{entry.client_name} · {entry.progress}%</p>
            <.dm_btn type="submit" variant="primary">{dgettext("admin", "Import candidate")}</.dm_btn>
          </.form>
        </.dm_card>
        <.dm_card>
          <:title>{dgettext("admin", "Compose a plugin")}</:title>
          <.form for={to_form(%{}, as: :compose)} id="plugin-compose-form" phx-submit="compose" class="space-y-4">
            <.dm_input name="compose[publisher]" label={dgettext("admin", "Publisher")} value="local" required />
            <.dm_select id="plugin-skill-revisions" name="compose[skills][]" label={dgettext("admin", "Exact skill revisions")} options={@skill_options} multiple helper={dgettext("admin", "All files from selected immutable revisions are copied into the release.")} />
            <.dm_textarea id="plugin-compose-manifest" name="compose[manifest]" label={dgettext("admin", "Standard plugin manifest (JSON)")} value={manifest_example()} rows={8} required />
            <.dm_textarea id="plugin-compose-mcp" name="compose[mcp]" label={dgettext("admin", "MCP declarations (JSON)")} value={mcp_example()} rows={5} />
            <.dm_btn type="submit" variant="secondary">{dgettext("admin", "Create candidate")}</.dm_btn>
          </.form>
        </.dm_card>
      </div>

      <.dm_card :if={@live_action in [:releases, :show]}>
        <:title>{dgettext("admin", "Client support")}</:title>
        <p class="text-sm text-on-surface-variant">{dgettext("admin", "Package validation, client capabilities and actual component state are separate results.")}</p>
        <div class="overflow-x-auto" role="region" aria-label={dgettext("admin", "Client support table")} tabindex="0">
          <.dm_table id="plugin-client-support" data={compatibility_rows()} style="min-width: 48rem" zebra>
            <:col :let={row} label={dgettext("admin", "Client")}>{row.client}</:col>
            <:col :let={row} label={dgettext("admin", "Skills and MCP")}>{row.portable}</:col>
            <:col :let={row} label={dgettext("admin", "Extensions")}>{row.extensions}</:col>
            <:col :let={row} label={dgettext("admin", "Evidence and limits")}>{row.evidence}</:col>
          </.dm_table>
        </div>
      </.dm_card>

      <.dm_card :if={@live_action in [:releases, :show]}>
        <:title>{if @selected,
            do: dgettext("admin", "%{identity} releases", identity: @selected.identity),
            else: dgettext("admin", "Release history")}</:title>
        <p :if={@releases == []}>{dgettext("admin", "No candidates or published releases.")}</p>
        <div :for={release <- @releases} id={"plugin-release-" <> release.id} class="border-b border-outline-variant py-4 space-y-3">
          <p class="font-semibold"><.dm_link navigate={~p"/plugins/#{release.plugin_id}"}>{plugin_name(@plugins, release.plugin_id)}</.dm_link></p>
          <p class="font-semibold">{release_label(release)}</p>
          <.dm_badge variant={if release.published_at, do: "success", else: "secondary"}>{if release.published_at, do: dgettext("admin", "Published"), else: dgettext("admin", "Candidate")}</.dm_badge>
          <p :for={channel <- Enum.filter(@channels, &(&1.release_id == release.id))} class="text-sm font-medium text-primary">{dgettext("admin", "Selected for channel: %{name}", name: channel.name)}</p>
          <dl class="text-sm break-all"><dt>{dgettext("admin", "Artifact SHA-256")}</dt><dd>{release.artifact_digest}</dd><dt>{dgettext("admin", "Source commit")}</dt><dd>{release.source_commit || dgettext("admin", "Uploaded / composed")}</dd></dl>
          <section id={"plugin-validation-" <> release.id} class="space-y-2">
            <h3 class="font-semibold">{dgettext("admin", "Package validation")}</h3>
            <p :if={release.diagnostics == []} class="text-sm">{dgettext("admin", "No package validation diagnostics.")}</p>
            <p :for={diagnostic <- release.diagnostics} class="text-sm">{diagnostic["severity"]} · {diagnostic["code"]} · {diagnostic["path"]}: {diagnostic["message"]}</p>
          </section>
          <section id={"plugin-actual-state-" <> release.id} class="space-y-2">
            <h3 class="font-semibold">{dgettext("admin", "Actual consumer state")}</h3>
            <p :if={release_installations(@installations, release.id) == []} class="text-sm">{dgettext("admin", "No consumer reports for this release.")}</p>
            <div :if={release_installations(@installations, release.id) != []} class="overflow-x-auto" role="region" aria-label={dgettext("admin", "Consumer component reports")} tabindex="0">
              <.dm_table id={"plugin-component-reports-" <> release.id} data={release_installations(@installations, release.id)} style="min-width: 48rem" zebra>
                <:col :let={installation} label={dgettext("admin", "Target")}>{installation.target}</:col>
                <:col :let={installation} label={dgettext("admin", "Actual release")}>{installation.actual_release_id || dgettext("admin", "Not reported")}</:col>
                <:col :let={installation} label={dgettext("admin", "State")}>{installation.status}</:col>
                <:col :let={installation} label={dgettext("admin", "Components")}><pre class="text-xs whitespace-pre-wrap">{Jason.encode!(installation.components, pretty: true)}</pre></:col>
              </.dm_table>
            </div>
          </section>
          <details><summary>{dgettext("admin", "Manifest, components and diagnostics (JSON)")}</summary><pre class="text-xs whitespace-pre-wrap">{Jason.encode!(%{manifest: release.manifest, diagnostics: release.diagnostics, provenance: release.provenance, components: @release_details[release.id]}, pretty: true)}</pre></details>
          <.form for={to_form(%{"id" => release.id, "channel" => "stable"}, as: :release)} id={"publish-" <> release.id} phx-submit="publish" class="flex flex-wrap items-end gap-3">
            <input type="hidden" name="release[id]" value={release.id} />
            <.dm_input name="release[channel]" label={dgettext("admin", "Channel")} value="stable" required />
            <.dm_btn type="submit" variant="secondary">{dgettext("admin", "Publish / select for channel")}</.dm_btn>
          </.form>
          <p class="text-sm text-on-surface-variant">{dgettext("admin", "Select an earlier published release to roll a channel back. Running sessions retain their locked release.")}</p>
        </div>
      </.dm_card>

      <div :if={@live_action == :sources} class="space-y-6">
        <.dm_card>
          <:title>{dgettext("admin", "Plugin sources")}</:title>
          <p :if={@sources == []}>{dgettext("admin", "No sources configured.")}</p>
          <div :for={source <- @sources} id={"plugin-source-" <> source.id} class="border-b border-outline-variant py-4 space-y-2">
            <h2 class="text-lg font-semibold">{source.name}</h2><p class="break-all">{source.url} · {source.ref} · {source.path}</p>
            <p>{source.status} · {if source.enabled,
                do: dgettext("admin", "Scheduled every %{seconds} seconds", seconds: source.interval_seconds),
                else: dgettext("admin", "Schedule paused")}</p>
            <p class="text-sm">{dgettext("admin", "Last attempt: %{attempt} · Last success: %{success}", attempt: source.last_attempt_at || dgettext("common", "Never"), success: source.last_success_at || dgettext("common", "Never"))}</p>
            <pre :if={source.diagnostics != []} class="text-xs whitespace-pre-wrap">{Jason.encode!(source.diagnostics, pretty: true)}</pre>
            <div class="flex gap-3"><.dm_btn phx-click="sync-source" phx-value-id={source.id} disabled={source.id in @busy} variant="secondary">{dgettext("admin", "Sync now")}</.dm_btn><.dm_btn phx-click="edit-source" phx-value-id={source.id} variant="ghost">{dgettext("common", "Edit")}</.dm_btn><.dm_btn phx-click="delete-source" phx-value-id={source.id} variant="error" confirm={dgettext("admin", "Remove this source? Published releases remain available.")}>{dgettext("common", "Delete")}</.dm_btn></div>
          </div>
        </.dm_card>
        <.dm_card>
          <:title>{if @editing_source, do: dgettext("admin", "Edit source"), else: dgettext("admin", "Add source")}</:title>
          <.form for={@source_form} id="plugin-source-form" phx-submit="save-source" class="space-y-4">
            <.dm_input field={@source_form[:name]} label={dgettext("admin", "Source name")} required />
            <.dm_input field={@source_form[:url]} label={dgettext("admin", "GitHub repository URL")} required />
            <.dm_input field={@source_form[:ref]} label={dgettext("admin", "Branch, tag or commit")} value={@source_form[:ref].value || "HEAD"} required />
            <.dm_input field={@source_form[:path]} label={dgettext("admin", "Plugin directory or marketplace manifest path")} />
            <.dm_select field={@source_form[:kind]} label={dgettext("admin", "Source type")} value={@source_form[:kind].value || "plugin"} options={[{"plugin", dgettext("admin", "Plugin repository / subdirectory")}, {"marketplace", dgettext("admin", "Codex marketplace")}]} />
            <.dm_select field={@source_form[:credential_name]} label={dgettext("admin", "Vault credential (optional)")} prompt={dgettext("admin", "Public repository")} options={@credentials} />
            <.dm_input field={@source_form[:interval_seconds]} type="number" label={dgettext("admin", "Sync interval (seconds, minimum 60)")} value={@source_form[:interval_seconds].value || 300} min="60" />
            <.dm_checkbox field={@source_form[:enabled]} label={dgettext("admin", "Enable scheduled sync")} checked={@source_form[:enabled].value not in [false, "false"]} />
            <.dm_checkbox field={@source_form[:auto_publish]} label={dgettext("admin", "Automatically publish valid synchronized candidates")} checked={@source_form[:auto_publish].value in [true, "true"]} />
            <div class="flex gap-3"><.dm_btn type="submit" variant="primary">{dgettext("admin", "Save source")}</.dm_btn><.dm_btn type="button" phx-click="cancel-source" variant="ghost">{dgettext("admin", "Cancel edit")}</.dm_btn></div>
          </.form>
        </.dm_card>
      </div>

      <div :if={@live_action == :distribution} class="space-y-6">
        <.dm_card>
          <:title>{dgettext("admin", "Desired and actual installations")}</:title>
          <p :if={@installations == []}>{dgettext("admin", "No consumer installations assigned.")}</p>
          <div :for={installation <- @installations} id={"plugin-installation-" <> installation.id} class="border-b border-outline-variant py-4 text-sm break-all">
            <p class="font-semibold">{installation.target} · {plugin_name(@plugins, installation.plugin_id)}</p>
            <p>{dgettext("admin", "Desired: %{release} · %{state}", release: installation.desired_release_id, state: if(installation.enabled, do: dgettext("common", "Enabled"), else: dgettext("common", "Disabled")))}</p>
            <p>{dgettext("admin", "Actual: %{release} · %{status} · %{enablement}", release: installation.actual_release_id || dgettext("admin", "Not reported"), status: installation.status, enablement: actual_enablement_text(installation.actual_enabled))}</p>
            <pre class="whitespace-pre-wrap">{Jason.encode!(installation.components, pretty: true)}</pre>
          </div>
          <.form for={to_form(%{}, as: :installation)} id="plugin-desired-form" phx-submit="desired" class="space-y-4 mt-4">
            <.dm_input name="installation[target]" label={dgettext("admin", "Consumer target")} placeholder="sigma:instance-id" required />
            <.dm_select name="installation[plugin_id]" label={dgettext("admin", "Plugin")} options={Enum.map(@plugins, &{&1.id, &1.identity})} />
            <.dm_select name="installation[release_id]" label={dgettext("admin", "Published release")} options={Enum.filter(@releases, & &1.published_at) |> Enum.map(&{&1.id, release_label(&1)})} />
            <.dm_checkbox name="installation[enabled]" label={dgettext("admin", "Desired enabled")} checked />
            <.dm_btn type="submit" variant="primary">{dgettext("admin", "Set desired installation")}</.dm_btn>
          </.form>
        </.dm_card>
        <.dm_card>
          <:title>{dgettext("admin", "Codex local marketplace")}</:title>
          <p class="text-sm text-on-surface-variant">{dgettext("admin", "Exports the selected releases. Codex installation and new-session activation are separate steps.")}</p>
          <.form for={to_form(%{}, as: :export)} id="plugin-export-form" phx-submit="export" class="space-y-4">
            <.dm_input name="export[directory]" label={dgettext("admin", "New destination directory")} required /><.dm_input name="export[channel]" label={dgettext("admin", "Channel")} value="stable" required /><.dm_input name="export[name]" label={dgettext("admin", "Marketplace name")} value="backplane" required />
            <.dm_select name="export[plugin_ids][]" label={dgettext("admin", "Plugin scope (leave empty for all)")} options={Enum.map(@plugins, &{&1.id, &1.identity})} multiple />
            <.dm_btn type="submit" variant="secondary">{dgettext("admin", "Export local snapshot")}</.dm_btn>
          </.form>
        </.dm_card>
        <.dm_card>
          <:title>{dgettext("admin", "Publish Codex Git marketplace")}</:title>
          <.form for={to_form(%{}, as: :git)} id="plugin-git-form" phx-submit="publish-git" class="space-y-4">
            <.dm_input name="git[url]" label={dgettext("admin", "Target HTTPS Git repository URL")} required /><.dm_input name="git[branch]" label={dgettext("admin", "Target branch")} value="main" required /><.dm_input name="git[channel]" label={dgettext("admin", "Channel")} value="stable" required /><.dm_input name="git[name]" label={dgettext("admin", "Marketplace name")} value="backplane" required />
            <.dm_select name="git[plugin_ids][]" label={dgettext("admin", "Plugin scope (leave empty for all)")} options={Enum.map(@plugins, &{&1.id, &1.identity})} multiple />
            <.dm_select name="git[credential_name]" label={dgettext("admin", "Publishing vault credential")} prompt={dgettext("admin", "Select credential")} options={@credentials} />
            <p class="text-sm text-on-surface-variant">{dgettext("admin", "HTTP Basic token authentication uses vault metadata git_username (default x-access-token) and the token as password. The target must accept this method. Redirects are disabled; live Gitea authentication has not been verified.")}</p>
            <.dm_btn type="submit" variant="secondary" confirm={dgettext("admin", "Commit and push selected plugin releases to this repository?")}>{dgettext("admin", "Commit and push marketplace")}</.dm_btn>
          </.form>
        </.dm_card>
        <pre :if={@export_result} id="plugin-export-result" class="whitespace-pre-wrap break-all text-xs">{Jason.encode!(@export_result, pretty: true)}</pre>
      </div>
    </div>
    """
  end
end
