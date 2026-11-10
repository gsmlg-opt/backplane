defmodule Backplane.HostAgent.PluginInstaller.CursorConfig do
  @moduledoc """
  Reversibly merges Backplane entries into Cursor's `hooks.json` and `mcp.json`.

  Backplane hook entries are recognised by a command containing
  `backplane-memory-hook`; the MCP entry by the `backplane-memory` server key.
  Everything else, including key order, is preserved. Each existing file is
  backed up once to `<file>.backplane-backup` and written atomically.
  """

  alias Jason.OrderedObject

  @hook_marker "backplane-memory-hook"
  @mcp_key "backplane-memory"
  @backup_suffix ".backplane-backup"

  @type error :: {:invalid_json, Path.t()} | {:file_error, term(), Path.t()}

  @doc "Path of Cursor's hooks file under `home`."
  def hooks_path(home), do: Path.join([home, ".cursor", "hooks.json"])

  @doc "Path of Cursor's MCP file under `home`."
  def mcp_path(home), do: Path.join([home, ".cursor", "mcp.json"])

  @doc "True when `hooks.json` carries at least one Backplane hook."
  def installed?(home) do
    case load(hooks_path(home)) do
      {:ok, %OrderedObject{} = doc} -> hooks_entries(doc) |> Enum.any?(&our_entry?/1)
      _other -> false
    end
  end

  @doc "True when both `hooks.json` and `mcp.json` carry Backplane entries."
  def valid?(home) do
    installed?(home) and mcp_installed?(home)
  end

  @doc """
  Merges the decoded (ordered) hooks and MCP templates into the user's files.

  Both files are validated before anything is written.
  """
  @spec install(Path.t(), OrderedObject.t(), OrderedObject.t()) :: :ok | {:error, error()}
  def install(home, hooks_template, mcp_template) do
    update(home, &merge_hooks(&1, hooks_template), &merge_mcp(&1, mcp_template), true)
  end

  @doc "Removes only the Backplane entries from both files."
  @spec remove(Path.t()) :: :ok | {:error, error()}
  def remove(home), do: update(home, &strip_hooks/1, &strip_mcp/1, false)

  defp mcp_installed?(home) do
    case load(mcp_path(home)) do
      {:ok, %OrderedObject{} = doc} -> doc |> servers() |> List.keymember?(@mcp_key, 0)
      _other -> false
    end
  end

  defp update(home, hooks_fun, mcp_fun, create?) do
    files = [{hooks_path(home), hooks_fun}, {mcp_path(home), mcp_fun}]

    with {:ok, loaded} <- load_all(files),
         {:ok, writes} <- plan(loaded, create?) do
      Enum.reduce_while(writes, :ok, fn {path, existing?, doc}, :ok ->
        case write(path, existing?, doc) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp load_all(files) do
    Enum.reduce_while(files, {:ok, []}, fn {path, fun}, {:ok, acc} ->
      case load(path) do
        {:ok, doc} -> {:cont, {:ok, [{path, fun, doc} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      error -> error
    end
  end

  defp plan(loaded, create?) do
    loaded
    |> Enum.reduce_while({:ok, []}, fn {path, fun, current}, {:ok, acc} ->
      case {current, create?} do
        {:missing, false} ->
          {:cont, {:ok, acc}}

        _present_or_create ->
          base = if current == :missing, do: OrderedObject.new([]), else: current

          case fun.(base) do
            {:ok, updated} when updated == current -> {:cont, {:ok, acc}}
            {:ok, updated} -> {:cont, {:ok, [{path, current != :missing, updated} | acc]}}
            :error -> {:halt, {:error, {:invalid_json, path}}}
          end
      end
    end)
    |> case do
      {:ok, writes} -> {:ok, Enum.reverse(writes)}
      error -> error
    end
  end

  defp load(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents, objects: :ordered_objects) do
          {:ok, %OrderedObject{} = doc} -> {:ok, doc}
          _invalid -> {:error, {:invalid_json, path}}
        end

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, {:file_error, reason, path}}
    end
  end

  # Hooks: {"version": 1, "hooks": {"<event>": [{"command": ...}]}}
  defp merge_hooks(doc, template) do
    with {:ok, hooks} <- fetch_object(doc, "hooks"),
         {:ok, kept} <- strip_events(hooks),
         {:ok, merged} <- append_events(kept, template |> field("hooks") |> pairs()) do
      {:ok,
       doc
       |> put_default("version", template_version(template))
       |> put("hooks", OrderedObject.new(merged))}
    end
  end

  defp strip_hooks(doc) do
    with {:ok, hooks} <- fetch_object(doc, "hooks"),
         {:ok, kept} <- strip_events(hooks) do
      if kept == hooks, do: {:ok, doc}, else: {:ok, put(doc, "hooks", OrderedObject.new(kept))}
    end
  end

  defp strip_events(events) do
    Enum.reduce_while(events, {:ok, []}, fn {event, entries}, {:ok, acc} ->
      case entries do
        list when is_list(list) ->
          kept = Enum.reject(list, &our_entry?/1)

          if kept == [] and list != [],
            do: {:cont, {:ok, acc}},
            else: {:cont, {:ok, [{event, kept} | acc]}}

        other ->
          {:cont, {:ok, [{event, other} | acc]}}
      end
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end

  defp append_events(events, ours) do
    Enum.reduce_while(ours, {:ok, events}, fn {event, entries}, {:ok, acc} ->
      case List.keyfind(acc, event, 0) do
        {^event, existing} when is_list(existing) ->
          {:cont, {:ok, List.keyreplace(acc, event, 0, {event, existing ++ entries})}}

        {^event, _not_a_list} ->
          {:halt, :error}

        nil ->
          {:cont, {:ok, acc ++ [{event, entries}]}}
      end
    end)
  end

  defp template_version(template) do
    case field(template, "version") do
      nil -> 1
      version -> version
    end
  end

  # MCP: {"mcpServers": {"<name>": {...}}}
  defp merge_mcp(doc, template) do
    with {:ok, servers} <- fetch_object(doc, "mcpServers") do
      ours = template |> field("mcpServers") |> pairs()
      kept = Enum.reject(servers, fn {key, _value} -> key == @mcp_key end)
      {:ok, put(doc, "mcpServers", OrderedObject.new(kept ++ ours))}
    end
  end

  defp strip_mcp(doc) do
    with {:ok, servers} <- fetch_object(doc, "mcpServers") do
      kept = Enum.reject(servers, fn {key, _value} -> key == @mcp_key end)

      if kept == servers,
        do: {:ok, doc},
        else: {:ok, put(doc, "mcpServers", OrderedObject.new(kept))}
    end
  end

  defp servers(doc) do
    case fetch_object(doc, "mcpServers") do
      {:ok, pairs} -> pairs
      :error -> []
    end
  end

  defp hooks_entries(doc) do
    case fetch_object(doc, "hooks") do
      {:ok, events} -> Enum.flat_map(events, fn {_event, entries} -> List.wrap(entries) end)
      :error -> []
    end
  end

  defp our_entry?(%OrderedObject{} = entry) do
    case field(entry, "command") do
      command when is_binary(command) -> String.contains?(command, @hook_marker)
      _other -> false
    end
  end

  defp our_entry?(_entry), do: false

  # Returns the key/value pairs of an object field; a missing field is empty.
  defp fetch_object(%OrderedObject{} = doc, key) do
    case field(doc, key) do
      nil -> {:ok, []}
      %OrderedObject{values: values} -> {:ok, values}
      _other -> :error
    end
  end

  defp pairs(%OrderedObject{values: values}), do: values
  defp pairs(_other), do: []

  defp field(%OrderedObject{values: values}, key) do
    case List.keyfind(values, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  defp field(_other, _key), do: nil

  defp put(%OrderedObject{values: values}, key, value) do
    if List.keymember?(values, key, 0),
      do: OrderedObject.new(List.keyreplace(values, key, 0, {key, value})),
      else: OrderedObject.new(values ++ [{key, value}])
  end

  defp put_default(%OrderedObject{values: values} = doc, key, value) do
    if List.keymember?(values, key, 0),
      do: doc,
      else: OrderedObject.new([{key, value} | values])
  end

  defp write(path, existing?, doc) do
    backup = path <> @backup_suffix
    tmp = path <> ".backplane-tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- backup_once(path, backup, existing?),
         :ok <- File.write(tmp, Jason.encode!(doc, pretty: true) <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:file_error, reason, path}}
    end
  end

  defp backup_once(path, backup, true) do
    if File.exists?(backup), do: :ok, else: File.cp(path, backup)
  end

  defp backup_once(_path, _backup, false), do: :ok
end
