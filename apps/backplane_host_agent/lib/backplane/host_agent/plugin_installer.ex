defmodule Backplane.HostAgent.PluginInstaller do
  @moduledoc """
  Installs packaged host-agent plugins for local agent runtimes.
  """

  @plugins %{
    "memory" => %{
      name: "backplane-memory",
      source_parts: ["integrations", "memory"],
      runtimes: %{
        "claude_code" => %{
          mode: :marketplace,
          uses_hook_client: true,
          required_files: [
            ".claude-plugin/marketplace.json",
            "backplane-memory/.claude-plugin/plugin.json",
            "backplane-memory/hooks/hooks.json",
            "backplane-memory/.mcp.json",
            "backplane-memory/skills/backplane-memory/SKILL.md"
          ],
          target_parts: ["plugins", "claude"],
          next_steps: [
            "claude plugin marketplace add {target}",
            "claude plugin install backplane-memory@backplane-local"
          ]
        },
        "hermes" => %{
          required_files: ["README.md", "plugin.yaml", "__init__.py"],
          target_parts: [".hermes", "plugins", "backplane-memory"]
        },
        "openclaw" => %{
          required_files: [
            "README.md",
            "package.json",
            "openclaw.plugin.json",
            "plugin.mjs",
            "contract.mjs",
            "journal.mjs",
            "client.mjs",
            "context.mjs",
            "service.mjs",
            "rollout.mjs",
            "plugin.yaml"
          ],
          target_parts: [".openclaw", "extensions", "backplane-memory"]
        }
      }
    }
  }

  @hook_client_name "backplane-memory-hook"
  @default_host_agent_url "http://127.0.0.1:4222"

  @doc "Returns supported packaged plugin ids."
  def plugins, do: @plugins |> Map.keys() |> Enum.sort()

  @doc "Returns supported runtimes for a plugin."
  def runtimes(plugin) do
    with {:ok, _plugin, meta} <- plugin_meta(plugin) do
      meta.runtimes |> Map.keys() |> Enum.sort()
    end
  end

  @doc "Returns install status for every supported plugin/runtime pair."
  def list(opts \\ %{}) when is_map(opts) do
    for plugin <- plugins_for_list(opts),
        runtime <- runtimes(plugin) do
      {:ok, status} = status(plugin, runtime, opts)
      status
    end
  end

  @doc "Returns install status for one plugin/runtime pair."
  def status(plugin, runtime, opts \\ %{}) when is_map(opts) do
    with {:ok, plugin, plugin_meta} <- plugin_meta(plugin),
         {:ok, runtime, runtime_meta} <- runtime_meta(plugin, plugin_meta, runtime),
         {:ok, target_path} <- target_path(plugin_meta, runtime_meta, opts),
         {:ok, source_path} <- source_dir(runtime, plugin_meta, opts) do
      {:ok, status_map(plugin, runtime, source_path, target_path, plugin_meta, runtime_meta)}
    end
  end

  @doc "Installs or updates a packaged plugin for a runtime."
  def install(plugin, runtime, opts \\ %{}) when is_map(opts) do
    with {:ok, plugin, plugin_meta} <- plugin_meta(plugin),
         {:ok, runtime, runtime_meta} <- runtime_meta(plugin, plugin_meta, runtime),
         {:ok, source_path} <- source_dir(runtime, plugin_meta, opts),
         :ok <- validate_source(source_path, runtime_meta),
         {:ok, target_path} <- target_path(plugin_meta, runtime_meta, opts),
         :ok <-
           install_files(
             plugin_meta,
             runtime_meta,
             source_path,
             target_path,
             parse_bool(opt(opts, :force), true),
             opts
           ) do
      {:ok, status_map(plugin, runtime, source_path, target_path, plugin_meta, runtime_meta)}
    end
  end

  @doc "Removes a packaged plugin install for a runtime."
  def remove(plugin, runtime, opts \\ %{}) when is_map(opts) do
    with {:ok, plugin, plugin_meta} <- plugin_meta(plugin),
         {:ok, runtime, runtime_meta} <- runtime_meta(plugin, plugin_meta, runtime),
         {:ok, target_path} <- target_path(plugin_meta, runtime_meta, opts),
         :ok <- guard_remove(runtime_meta, target_path),
         :ok <- remove_existing(target_path),
         :ok <- cleanup_hook_client(plugin_meta, runtime, runtime_meta, opts),
         {:ok, source_path} <- source_dir(runtime, plugin_meta, opts) do
      {:ok, status_map(plugin, runtime, source_path, target_path, plugin_meta, runtime_meta)}
    end
  end

  defp plugin_meta(plugin) when is_atom(plugin), do: plugin |> Atom.to_string() |> plugin_meta()

  defp plugin_meta(plugin) when is_binary(plugin) do
    normalized =
      plugin
      |> String.downcase()
      |> String.trim()

    case Map.fetch(@plugins, normalized) do
      {:ok, meta} -> {:ok, normalized, meta}
      :error -> {:error, {:unsupported_plugin, plugin}}
    end
  end

  defp plugin_meta(plugin), do: {:error, {:unsupported_plugin, plugin}}

  defp plugins_for_list(opts) do
    case opt(opts, :plugin) do
      nil -> plugins()
      "" -> plugins()
      plugin -> if plugin in plugins(), do: [plugin], else: []
    end
  end

  defp runtime_meta(plugin, plugin_meta, runtime) when is_atom(runtime) do
    runtime |> Atom.to_string() |> then(&runtime_meta(plugin, plugin_meta, &1))
  end

  defp runtime_meta(plugin, plugin_meta, runtime) when is_binary(runtime) do
    normalized =
      runtime
      |> String.downcase()
      |> String.trim()

    case Map.fetch(plugin_meta.runtimes, normalized) do
      {:ok, meta} -> {:ok, normalized, meta}
      :error -> {:error, {:unsupported_runtime, plugin, runtime}}
    end
  end

  defp runtime_meta(plugin, _plugin_meta, runtime),
    do: {:error, {:unsupported_runtime, plugin, runtime}}

  defp source_dir(runtime, plugin_meta, opts) do
    source_root =
      opt(opts, :source_root) ||
        Application.get_env(:backplane_host_agent, :plugin_source_root) ||
        bundled_source_root(plugin_meta)

    source_path = Path.expand(Path.join(source_root, runtime))

    if File.dir?(source_path) do
      {:ok, source_path}
    else
      {:error, {:source_missing, source_path}}
    end
  end

  defp bundled_source_root(plugin_meta) do
    priv_root =
      case :code.priv_dir(:backplane_host_agent) do
        path when is_list(path) -> Path.join([to_string(path) | plugin_meta.source_parts])
        {:error, _reason} -> nil
      end

    if priv_root && File.dir?(priv_root) do
      priv_root
    else
      Path.expand(Path.join([__DIR__, "../../../../../" | plugin_meta.source_parts]))
    end
  end

  defp validate_source(source_path, %{required_files: required_files}) do
    case Enum.find(required_files, &(not File.regular?(Path.join(source_path, &1)))) do
      nil -> :ok
      file -> {:error, {:source_missing_file, file}}
    end
  end

  defp target_path(plugin_meta, runtime_meta, opts) do
    home_dir = home_dir(opts)

    path =
      case {runtime_meta, opt(opts, :target_path)} do
        {%{mode: :marketplace}, _path} ->
          Path.join([default_base(runtime_meta, home_dir, opts) | runtime_meta.target_parts])

        {_meta, path} when is_binary(path) and path != "" ->
          Path.expand(path, home_dir)

        _other ->
          Path.join([default_base(runtime_meta, home_dir, opts) | runtime_meta.target_parts])
      end

    with :ok <- validate_target_path(path, home_dir, target_name(plugin_meta, runtime_meta)) do
      {:ok, path}
    end
  end

  defp default_base(%{mode: :marketplace}, home_dir, opts), do: data_dir(opts, home_dir)
  defp default_base(_runtime_meta, home_dir, _opts), do: home_dir

  defp target_name(_plugin_meta, %{mode: :marketplace, target_parts: parts}), do: List.last(parts)
  defp target_name(plugin_meta, _runtime_meta), do: plugin_meta.name

  defp data_dir(opts, home_dir) do
    case opt(opts, :data_dir) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir, home_dir)
      _dir -> Path.join([home_dir, ".local", "share", "backplane"])
    end
  end

  defp home_dir(opts) do
    opt(opts, :home_dir) ||
      Application.get_env(:backplane_host_agent, :home_dir) ||
      System.user_home!()
  end

  defp validate_target_path(path, home_dir, plugin_name) do
    expanded_path = Path.expand(path)
    expanded_home = Path.expand(home_dir)

    cond do
      Path.basename(expanded_path) != plugin_name ->
        {:error, {:invalid_target, expanded_path}}

      not under_path?(expanded_path, expanded_home) ->
        {:error, {:target_outside_home, expanded_path}}

      true ->
        :ok
    end
  end

  defp under_path?(path, root) do
    path == root || String.starts_with?(path, root <> "/")
  end

  defp install_files(plugin_meta, %{mode: :marketplace}, source, target, force?, opts) do
    home = home_dir(opts)
    data = data_dir(opts, home)
    client = Path.join([data, "bin", @hook_client_name])

    with :ok <- validate_data_dir(data, home),
         {:ok, url} <- host_agent_url(opts),
         :ok <- ensure_marketplace_target(target),
         substitutions = %{
           "__HOOK_CLIENT__" => shell_quote(client),
           "__HOST_AGENT_URL__" => url
         },
         :ok <- install_hook_client(source, client, url) do
      replace_dir(plugin_meta.name, source, target, force?, &render_tree(&1, substitutions))
    end
  end

  defp install_files(plugin_meta, _runtime_meta, source, target, force?, _opts),
    do: replace_dir(plugin_meta.name, source, target, force?)

  # Never replace or remove a directory that is not our marketplace.
  defp ensure_marketplace_target(target) do
    if File.exists?(target) do
      with {:ok, json} <- File.read(Path.join(target, ".claude-plugin/marketplace.json")),
           {:ok, %{"name" => "backplane-local"}} <- Jason.decode(json) do
        :ok
      else
        _other -> {:error, :unexpected_target_contents}
      end
    else
      :ok
    end
  end

  defp guard_remove(%{mode: :marketplace}, target), do: ensure_marketplace_target(target)
  defp guard_remove(_runtime_meta, _target), do: :ok

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp validate_data_dir(data, home) do
    if under_path?(Path.expand(data), Path.expand(home)),
      do: :ok,
      else: {:error, {:target_outside_home, Path.expand(data)}}
  end

  # Replaces placeholders in every rendered `.json` file under `dir`.
  defp render_tree(dir, substitutions) do
    # fold_files treats `dir` literally (Path.wildcard would interpret `\`, `{`, `[`).
    dir
    |> String.to_charlist()
    |> :filelib.fold_files(~c".*\\.json$", true, &[List.to_string(&1) | &2], [])
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.write(path, substitute(File.read!(path), substitutions, &json_escape/1)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:file_error, reason, path}}}
      end
    end)
  end

  defp substitute(contents, substitutions, escape) do
    Enum.reduce(substitutions, contents, fn {placeholder, value}, acc ->
      String.replace(acc, placeholder, escape.(value))
    end)
  end

  defp json_escape(value), do: value |> Jason.encode!() |> String.slice(1..-2//1)

  # The shared hook client lives next to the runtime package directories.
  defp install_hook_client(source_path, client, url) do
    template = Path.join([Path.dirname(source_path), "shared", "bin", @hook_client_name])
    staging = client <> ".install-#{System.unique_integer([:positive])}"

    with {:ok, contents} <- File.read(template),
         :ok <- File.mkdir_p(Path.dirname(client)),
         :ok <-
           File.write(staging, String.replace(contents, "__HOST_AGENT_URL__", url)),
         :ok <- File.chmod(staging, 0o755),
         :ok <- File.rename(staging, client) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(staging)
        {:error, {:file_error, reason, template}}
    end
  end

  # Removes the shared hook client once no other hook-client runtime is installed.
  defp cleanup_hook_client(plugin_meta, runtime, %{uses_hook_client: true}, opts) do
    home = home_dir(opts)
    others = Map.delete(hook_client_runtimes(plugin_meta, opts), runtime)

    if Enum.any?(others, fn {_name, meta} -> runtime_installed?(plugin_meta, meta, opts) end) do
      :ok
    else
      remove_existing(Path.join([data_dir(opts, home), "bin", @hook_client_name]))
    end
  end

  defp cleanup_hook_client(_plugin_meta, _runtime, _runtime_meta, _opts), do: :ok

  defp hook_client_runtimes(plugin_meta, opts) do
    plugin_meta.runtimes
    |> Map.merge(opt(opts, :extra_runtimes) || %{})
    |> Map.filter(fn {_name, meta} -> Map.get(meta, :uses_hook_client, false) end)
  end

  defp runtime_installed?(plugin_meta, runtime_meta, opts) do
    opts = opts |> Map.delete(:target_path) |> Map.delete("target_path")

    case target_path(plugin_meta, runtime_meta, opts) do
      {:ok, path} -> File.dir?(path)
      _error -> false
    end
  end

  defp host_agent_url(opts) do
    url =
      (opt(opts, :host_agent_url) || Application.get_env(:backplane_host_agent, :host_agent_url) ||
         configured_host_agent_url() || @default_host_agent_url)
      |> to_string()
      |> String.trim_trailing("/")

    with false <- Regex.match?(~r/["'\\$`\s[:cntrl:]]/u, url),
         {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] <- URI.new(url),
         true <- is_binary(host) and host != "" do
      {:ok, url}
    else
      _other -> {:error, :invalid_host_agent_url}
    end
  end

  defp configured_host_agent_url do
    case Backplane.HostAgent.Config.load_default() do
      {:ok, %{http_bind: bind, http_port: port}} when is_integer(port) and port > 0 ->
        "http://#{bind || "127.0.0.1"}:#{port}"

      _other ->
        nil
    end
  end

  defp replace_dir(plugin_name, source_path, target_path, force?, prepare \\ fn _ -> :ok end) do
    parent = Path.dirname(target_path)
    staging = Path.join(parent, ".#{plugin_name}.install-#{System.unique_integer([:positive])}")

    result =
      with :ok <- File.mkdir_p(parent),
           :ok <- ensure_replace_allowed(target_path, force?),
           {:ok, _copied} <- File.cp_r(source_path, staging),
           :ok <- prepare.(staging),
           :ok <- remove_existing(target_path),
           :ok <- File.rename(staging, target_path) do
        :ok
      else
        {:error, reason, file} -> {:error, {:file_error, reason, file}}
        {:error, reason} -> {:error, reason}
      end

    if result != :ok do
      _ = File.rm_rf(staging)
    end

    result
  end

  defp ensure_replace_allowed(target_path, false) do
    if File.exists?(target_path), do: {:error, {:already_installed, target_path}}, else: :ok
  end

  defp ensure_replace_allowed(_target_path, true), do: :ok

  defp remove_existing(target_path) do
    case File.rm_rf(target_path) do
      {:ok, _removed} -> :ok
      {:error, reason, file} -> {:error, {:file_error, reason, file}}
    end
  end

  defp status_map(plugin, runtime, source_path, target_path, plugin_meta, runtime_meta) do
    %{
      "plugin" => plugin,
      "runtime" => runtime,
      "name" => plugin_meta.name,
      "installed" => File.dir?(target_path),
      "valid" => installed_valid?(target_path, runtime_meta),
      "source_path" => source_path,
      "target_path" => target_path
    }
    |> put_next_steps(runtime_meta, target_path)
  end

  defp put_next_steps(status, %{next_steps: steps}, target_path),
    do:
      Map.put(status, "next_steps", Enum.map(steps, &String.replace(&1, "{target}", target_path)))

  defp put_next_steps(status, _runtime_meta, _target_path), do: status

  defp installed_valid?(target_path, %{required_files: required_files}) do
    File.dir?(target_path) &&
      Enum.all?(required_files, &File.regular?(Path.join(target_path, &1)))
  end

  defp opt(map, key) do
    Map.get(map, Atom.to_string(key)) || Map.get(map, key)
  end

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when is_boolean(value), do: value
  defp parse_bool("true", _default), do: true
  defp parse_bool("false", _default), do: false
  defp parse_bool(_value, default), do: default
end
