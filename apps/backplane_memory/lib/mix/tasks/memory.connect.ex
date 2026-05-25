defmodule Mix.Tasks.Memory.Connect do
  @shortdoc "Install backplane-memory hooks into ~/.claude/settings.json"

  @moduledoc """
  Merges the 10 backplane-memory hook scripts into `~/.claude/settings.json`.

  Each hook entry points to the corresponding shell script in `priv/hooks/`.
  Running the task multiple times is idempotent: existing entries are updated
  in-place rather than duplicated.

  ## Examples

      mix memory.connect

  """

  use Mix.Task

  @hooks [
    {"PreToolUse", "session-start.sh"},
    {"UserPromptSubmit", "user-prompt-submit.sh"},
    {"PostToolUse", "post-tool-use.sh"},
    {"PostToolUse", "post-tool-use-failure.sh"},
    {"PreCompact", "pre-compact.sh"},
    {"SubagentStart", "subagent-start.sh"},
    {"SubagentStop", "subagent-stop.sh"},
    {"Stop", "stop.sh"},
    {"PostToolUse", "session-end.sh"},
    {"PostToolUse", "post-commit.sh"}
  ]

  @impl true
  def run(_args) do
    hooks_dir = hooks_priv_dir()
    settings_path = settings_file_path()

    ensure_settings_file(settings_path)

    current = read_settings(settings_path)
    updated = merge_hooks(current, hooks_dir)

    write_settings(settings_path, updated)

    Mix.shell().info("backplane-memory: #{length(@hooks)} hook(s) written to #{settings_path}")
  end

  defp hooks_priv_dir do
    # Prefer compiled priv dir, fall back to source tree for dev use
    case :code.priv_dir(:backplane_memory) do
      {:error, _} ->
        Path.join([__DIR__, "..", "..", "..", "..", "priv", "hooks"]) |> Path.expand()

      dir ->
        Path.join(to_string(dir), "hooks")
    end
  end

  defp settings_file_path do
    Path.join([System.user_home!(), ".claude", "settings.json"])
  end

  defp ensure_settings_file(path) do
    dir = Path.dirname(path)

    unless File.exists?(dir) do
      File.mkdir_p!(dir)
    end

    unless File.exists?(path) do
      File.write!(path, "{}\n")
    end
  end

  defp read_settings(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  rescue
    _ -> %{}
  end

  defp merge_hooks(settings, hooks_dir) do
    existing_hooks = Map.get(settings, "hooks", [])

    updated_hooks = do_merge_hooks(existing_hooks, hooks_dir)

    Map.put(settings, "hooks", updated_hooks)
  end

  defp do_merge_hooks(existing, hooks_dir) do
    # Collect canonical entries for every hook script we manage.
    new_entries =
      @hooks
      |> Enum.map(fn {event, script} ->
        script_path = Path.join(hooks_dir, script)

        %{
          "event" => event,
          "hooks" => [%{"type" => "command", "command" => script_path}]
        }
      end)

    # Remove any existing entries whose command path matches one we are adding,
    # then append our canonical set at the end.
    our_paths = Enum.map(new_entries, fn e -> get_in(e, ["hooks", Access.at(0), "command"]) end)

    kept =
      Enum.reject(existing, fn entry ->
        hooks = get_in(entry, ["hooks"]) || []
        Enum.any?(hooks, fn h -> h["command"] in our_paths end)
      end)

    kept ++ new_entries
  end

  defp write_settings(path, settings) do
    encoded = Jason.encode!(settings, pretty: true)
    File.write!(path, encoded <> "\n")
  end
end
