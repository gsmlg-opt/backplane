defmodule Backplane.CDP.MCP.Logpoints do
  @moduledoc "Session-owned, non-pausing console probes on parsed page scripts."

  alias Backplane.CDP.MCP.{Observer, Pages, ScriptSources, SourceMap}

  @location ~r/\A(\S+?):([0-9]{1,9})(?::([0-9]{1,9}))?\s+(\S.*)\z/s
  @argument ~r/\A\s*("(?:[^"\\\r\n]|\\.)*"|'(?:[^'\\\r\n]|\\['\\])*'|-?\d+(?:\.\d+)?|[a-zA-Z_$][\w$]*(?:\.[a-zA-Z_$][\w$]*)*)\s*(,|\z)/
  @limit 100

  def call("set_logpoints", args, state) do
    with {:ok, requested} <- parse(args["logpoints"]),
         {:ok, target, state} <- Pages.selected(args, state) do
      pid = state.observers[target]

      case replace(pid, requested) do
        {:ok, message} -> {:ok, [%{"type" => "text", "text" => message}], state}
        {:error, message} -> {:error, message, state}
      end
    else
      {:error, message} -> {:error, message, state}
      other -> other
    end
  end

  def refresh(pid) do
    with {:ok, [_ | _] = entries} <- Observer.watched_logpoints(pid), do: replace(pid, entries)
  end

  defp parse(entries) when length(entries) > @limit,
    do: {:error, "At most #{@limit} logpoints can be set on one page."}

  defp parse(entries), do: traverse(entries, &parse_entry/1)

  defp parse_entry(text) when byte_size(text) <= 4096 do
    with [url, line, column, source] <-
           Regex.run(@location, String.trim(text), capture: :all_but_first),
         line when line > 0 <- String.to_integer(line),
         column when column != 0 <- if(column != "", do: String.to_integer(column)),
         {:ok, args} <- arguments(source) do
      {:ok,
       %{
         url: url,
         line: line,
         column: column,
         source: source,
         condition: "(console.log(#{Enum.join(args, ", ")}), false)"
       }}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         "Expected <url>:<line>[:<column>] <expression> with 1-based line and column numbers."}
    end
  end

  defp parse_entry(_), do: {:error, "A logpoint must be at most 4096 bytes."}

  # Only literal values and identifier paths are admitted. Re-encode quoted values
  # so even punctuation resembling JavaScript stays inside a string literal.
  defp arguments(source) do
    with [match, value, separator] <- Regex.run(@argument, source),
         {:ok, value} <- argument(value) do
      if separator == "" do
        {:ok, [value]}
      else
        with {:ok, rest} <-
               arguments(
                 binary_part(source, byte_size(match), byte_size(source) - byte_size(match))
               ),
             do: {:ok, [value | rest]}
      end
    else
      _ -> {:error, "Logpoint arguments must be literals, variables, or dotted property names."}
    end
  end

  defp argument("\"" <> _ = quoted) do
    with {:ok, value} <- Formata.JSON.decode(quoted), do: {:ok, Formata.JSON.encode!(value)}
  end

  defp argument("'" <> quoted) do
    value = quoted |> String.replace_suffix("'", "") |> String.replace(~r/\\(['\\])/, "\\1")
    {:ok, Formata.JSON.encode!(value)}
  end

  defp argument(value), do: {:ok, value}

  defp replace(pid, []) do
    with {:ok, _} <- Observer.command(pid, "Debugger.disable", %{}),
         :ok <- Observer.watch_logpoints(pid, []),
         do: {:ok, summary([])}
  end

  defp replace(pid, requested) do
    with :ok <- syntax(pid, requested),
         :ok <- enable(pid),
         {:ok, scripts} <- Observer.scripts(pid),
         urls = Map.keys(scripts),
         maps =
           if(Enum.all?(requested, &(&1.url in urls and scripts[&1.url] in [nil, ""])),
             do: [],
             else: ScriptSources.maps(pid, scripts)
           ),
         {:ok, resolved} <- traverse(requested, &resolve(&1, urls, maps)),
         {:ok, _} <- Observer.command(pid, "Debugger.disable", %{}),
         :ok <- enable(pid) do
      # Two suffixes can address the same source. The last expression wins.
      entries = resolved |> Enum.reverse() |> Enum.uniq_by(&{&1.url, &1.line}) |> Enum.reverse()

      case traverse(entries, &bind(pid, &1)) do
        {:ok, bindings} ->
          watched = if Enum.any?(entries, &Map.has_key?(&1, :generated)), do: requested, else: []
          with :ok <- Observer.watch_logpoints(pid, watched), do: {:ok, summary(bindings)}

        {:error, message} ->
          with {:ok, _} <- Observer.command(pid, "Debugger.disable", %{}),
               :ok <- Observer.watch_logpoints(pid, []),
               do: {:error, "#{message} The page logpoints have been cleared."}
      end
    end
  end

  defp syntax(pid, requested) do
    # Let V8 validate identifier/keyword use before replacing active logpoints.
    expression = Enum.map_join(requested, ";\n", & &1.condition)

    case Observer.command(pid, "Runtime.compileScript", %{
           "expression" => expression,
           "sourceURL" => "",
           "persistScript" => false
         }) do
      {:ok, %{"exceptionDetails" => details}} ->
        {:error, details["text"] || "Invalid logpoint expression."}

      {:ok, _} ->
        :ok

      error ->
        error
    end
  end

  defp enable(pid) do
    with {:ok, _} <- Observer.command(pid, "Debugger.enable", %{}),
         {:ok, _} <- Observer.command(pid, "Debugger.setSkipAllPauses", %{"skip" => true}),
         do: :ok
  end

  defp resolve(entry, urls, maps) do
    candidates =
      Enum.map(maps, fn {script, base, map} ->
        case SourceMap.resolve(map, base, entry.url, entry.line, entry.column) do
          {:ok, loc} -> {:ok, loc.url, {script, loc.line, loc.column}}
          other -> other
        end
      end)

    by_source =
      for {:ok, source, location} <- candidates, reduce: %{} do
        acc -> Map.update(acc, source, [location], &[location | &1])
      end

    case Map.to_list(by_source) do
      [] ->
        case resolve_script(entry, urls) do
          {:ok, _} = direct -> direct
          error -> Enum.find(candidates, error, &match?({:error, _}, &1))
        end

      [{url, locations}] ->
        {:ok, Map.put(%{entry | url: url}, :generated, Enum.uniq(locations))}

      _ ->
        {:error, "Multiple sources match #{entry.url}. Specify an absolute source URL."}
    end
  end

  defp resolve_script(entry, urls) do
    matches = Enum.filter(urls, &String.ends_with?(&1, "/" <> entry.url))

    cond do
      entry.url in urls ->
        {:ok, entry}

      length(matches) == 1 ->
        {:ok, %{entry | url: hd(matches)}}

      matches == [] ->
        {:error, "No parsed script matches \"#{entry.url}\". Use the URL of the served script."}

      true ->
        {:error, "\"#{entry.url}\" matches multiple sources. Specify a longer path."}
    end
  end

  defp bind(pid, entry) do
    locations = Map.get(entry, :generated, [{entry.url, entry.line, entry.column || 1}])

    with {:ok, bound} <- traverse(locations, &set_breakpoint(pid, entry.condition, &1)) do
      bound = Enum.reject(bound, &is_nil/1)

      status =
        cond do
          bound == [] -> "not bound (no parsed script contains the location)"
          Map.has_key?(entry, :generated) -> "bound via source map at " <> Enum.join(bound, ", ")
          true -> "bound"
        end

      column = if entry.column, do: ":#{entry.column}", else: ""
      {:ok, "- #{entry.url}:#{entry.line}#{column} logging `#{entry.source}` [#{status}]"}
    end
  end

  defp set_breakpoint(pid, condition, {url, line, col}) do
    params = %{
      "url" => url,
      "lineNumber" => line - 1,
      "columnNumber" => col - 1,
      "condition" => condition
    }

    case Observer.command(pid, "Debugger.setBreakpointByUrl", params) do
      {:ok, %{"locations" => []}} ->
        {:ok, nil}

      {:ok, %{"locations" => [loc | _]}} ->
        {:ok, "#{url}:#{loc["lineNumber"] + 1}:#{loc["columnNumber"] + 1}"}

      {:error, _} = error ->
        error

      _ ->
        {:error, "Chrome returned an invalid logpoint response."}
    end
  end

  defp summary([]), do: "No logpoints are set on the page."

  defp summary(lines),
    do:
      "#{length(lines)} logpoint(s) set on the page:\n" <>
        Enum.join(lines, "\n") <>
        "\nLogged output appears in list_console_messages once a line executes."

  defp traverse(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn x, {:ok, acc} ->
      case fun.(x) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
