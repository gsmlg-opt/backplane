defmodule Mix.Tasks.Memory.Connect do
  @shortdoc "Install backplane-memory hooks into ~/.claude/settings.json"

  @moduledoc """
  Merges the backplane-memory hook scripts into `~/.claude/settings.json`.

  The generated settings use Claude Code's event-keyed hook format. Running
  the task multiple times is idempotent and preserves hooks it does not manage.

  ## Examples

      mix memory.connect

  """

  use Mix.Task

  @hooks [
    {"SessionStart", nil, "session-start.sh", %{}},
    {"SessionEnd", nil, "session-end.sh", %{"timeout" => 3}},
    {"UserPromptSubmit", nil, "user-prompt-submit.sh", %{}},
    {"PostToolUse", nil, "post-tool-use.sh", %{}},
    {"PostToolUseFailure", nil, "post-tool-use-failure.sh", %{}},
    {"PreCompact", nil, "pre-compact.sh", %{}},
    {"SubagentStart", nil, "subagent-start.sh", %{}},
    {"SubagentStop", nil, "subagent-stop.sh", %{}},
    {"Stop", nil, "stop.sh", %{}},
    {"PostToolUse", "Bash", "post-commit.sh", %{}}
  ]

  @managed_scripts Enum.map(@hooks, &elem(&1, 2))

  @impl true
  def run(_args) do
    hooks_dir = hooks_priv_dir()
    settings_path = settings_file_path()

    ensure_settings_file(settings_path)

    settings_path
    |> read_settings()
    |> merge_hooks(hooks_dir)
    |> then(&write_settings(settings_path, &1))

    Mix.shell().info("backplane-memory: #{length(@hooks)} hook(s) written to #{settings_path}")
  end

  defp hooks_priv_dir do
    case :code.priv_dir(:backplane_memory) do
      {:error, _} ->
        Path.join([__DIR__, "..", "..", "..", "priv", "hooks"]) |> Path.expand()

      dir ->
        Path.join(to_string(dir), "hooks")
    end
  end

  defp settings_file_path do
    home = System.get_env("HOME") || System.user_home!()
    Path.join([home, ".claude", "settings.json"])
  end

  defp ensure_settings_file(path) do
    File.mkdir_p!(Path.dirname(path))

    unless File.exists?(path) do
      File.write!(path, "{}\n")
    end
  end

  defp read_settings(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp merge_hooks(settings, hooks_dir) when is_map(settings) do
    existing_hooks =
      settings
      |> Map.get("hooks", %{})
      |> normalize_hooks()
      |> remove_managed_handlers()

    updated_hooks =
      Enum.reduce(@hooks, existing_hooks, fn spec, hooks ->
        {event, _matcher, _script, _handler_options} = spec
        group = hook_group(spec, hooks_dir)
        Map.update(hooks, event, [group], &(&1 ++ [group]))
      end)

    Map.put(settings, "hooks", updated_hooks)
  end

  defp merge_hooks(_settings, _hooks_dir) do
    Mix.raise("~/.claude/settings.json must contain a JSON object")
  end

  defp normalize_hooks(hooks) when is_map(hooks) do
    Enum.each(hooks, fn
      {event, groups} when is_binary(event) and is_list(groups) -> :ok
      _ -> Mix.raise("hooks must map event names to matcher groups")
    end)

    hooks
  end

  defp normalize_hooks(hooks) when is_list(hooks) do
    Enum.reduce(hooks, %{}, fn
      %{"event" => event} = entry, acc when is_binary(event) and event != "" ->
        group = Map.delete(entry, "event")
        Map.update(acc, event, [group], &(&1 ++ [group]))

      _entry, _acc ->
        Mix.raise("legacy hooks must contain an event name")
    end)
  end

  defp normalize_hooks(_hooks) do
    Mix.raise("hooks must be an event-keyed object or the legacy flat list")
  end

  defp remove_managed_handlers(hooks) do
    Enum.reduce(hooks, %{}, fn {event, groups}, acc ->
      case Enum.flat_map(groups, &remove_managed_from_group/1) do
        [] -> acc
        kept_groups -> Map.put(acc, event, kept_groups)
      end
    end)
  end

  defp remove_managed_from_group(%{"hooks" => handlers} = group) when is_list(handlers) do
    kept = Enum.reject(handlers, &managed_handler?/1)

    if kept == [] and handlers != [] do
      []
    else
      [Map.put(group, "hooks", kept)]
    end
  end

  defp remove_managed_from_group(group), do: [group]

  defp managed_handler?(%{"type" => "command", "command" => command}) when is_binary(command) do
    Path.basename(command) in @managed_scripts and
      String.contains?(Path.expand(command), "backplane_memory/priv/hooks/")
  end

  defp managed_handler?(_handler), do: false

  defp hook_group({_event, matcher, script, handler_options}, hooks_dir) do
    handler =
      %{
        "type" => "command",
        "command" => Path.join(hooks_dir, script),
        "args" => []
      }
      |> Map.merge(handler_options)

    %{"hooks" => [handler]}
    |> maybe_put_matcher(matcher)
  end

  defp maybe_put_matcher(group, nil), do: group
  defp maybe_put_matcher(group, matcher), do: Map.put(group, "matcher", matcher)

  defp write_settings(path, settings) do
    encoded = Jason.encode!(settings, pretty: true)
    File.write!(path, encoded <> "\n")
  end
end
