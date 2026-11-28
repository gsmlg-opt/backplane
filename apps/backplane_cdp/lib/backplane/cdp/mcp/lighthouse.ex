defmodule Backplane.CDP.MCP.Lighthouse do
  @moduledoc """
  Runs Chrome's bundled Lighthouse engine through its connected DevTools frontend.
  """

  alias Backplane.CDP.Client
  alias Backplane.CDP.MCP.{Artifacts, Diagnostics, Observer, Pages}

  @external_resource Path.expand("../../../../priv/cdp/lighthouse.js", __DIR__)
  @audit_script File.read!(@external_resource)
  @ready_script "(async(target)=>{if(location.protocol!=='devtools:'||location.host!=='devtools'||!location.pathname.startsWith('/bundled/'))throw Error('Untrusted DevTools frontend');const SDK=await import('./core/sdk/sdk.js');return SDK.TargetManager.TargetManager.instance().primaryPageTarget()?.id()===target})"
  @audit_timeout 120_000

  def call("lighthouse_audit", args, state) do
    with {:ok, paths} <- report_paths(args["outputDirPath"]),
         {:ok, target, state} <- Pages.selected(args, state),
         {:ok, url} <- audit_url(args, target, state),
         {:ok, lease, frontend, token} <- lease(target, args, state) do
      try do
        options = %{
          url: url,
          targetId: target,
          token: token,
          mode: args["mode"] || "navigation",
          device: args["device"] || "desktop"
        }

        result = Client.with_connection(state.port, frontend, &audit(&1, options), @audit_timeout)
        finish(result, paths, state)
      after
        release(lease)
      end
    else
      {:error, message, state} -> {:error, message, state}
      {:error, message} -> {:error, message, state}
    end
  end

  defp audit_url(args, target, state) do
    id = Enum.find_value(state.pages, fn {id, value} -> if value == target, do: id end)
    url = state.page_info[id]["url"]

    if Map.get(args, "mode", "navigation") == "navigation" do
      case URI.new(url) do
        {:ok, %URI{scheme: scheme}} when scheme in ["http", "https", "chrome"] ->
          {:ok, url}

        _ ->
          {:error,
           "Lighthouse \"navigation\" mode cannot audit #{url}: it only supports http:, https:, chrome: and chrome-extension: URLs. Use mode \"snapshot\" to audit the page in its current state."}
      end
    else
      {:ok, url}
    end
  end

  defp lease(target, args, state) do
    owner = self()
    ref = make_ref()
    reply_alias = Process.alias()
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    {pid, monitor} =
      spawn_monitor(fn -> own_frontend(owner, reply_alias, ref, target, token, args, state) end)

    receive do
      {^ref, {:ok, frontend}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, {pid, reply_alias, ref}, frontend, token}

      {^ref, {:error, message}} ->
        Process.unalias(reply_alias)
        Process.demonitor(monitor, [:flush])
        {:error, message}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        Process.unalias(reply_alias)
        Process.demonitor(monitor, [:flush])
        {:error, "Lighthouse frontend could not start"}
    after
      40_000 ->
        send(pid, {ref, :release})
        Process.unalias(reply_alias)
        Process.demonitor(monitor, [:flush])
        {:error, "Lighthouse frontend connection timed out"}
    end
  end

  defp own_frontend(owner, reply_alias, ref, target, token, args, state) do
    owner_monitor = Process.monitor(owner)
    lock = {{__MODULE__, state.port, target}, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        case frontend(state.port, target) do
          {:ok, id, created} ->
            case wait_frontend(state.port, id, System.monotonic_time(:millisecond) + 10_000) do
              :ok ->
                send(reply_alias, {ref, {:ok, id}})

              {:error, message} ->
                send(reply_alias, {ref, {:error, message}})
                send(self(), {ref, :release})
            end

            receive do
              {^ref, :release} -> :ok
              {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
            after
              @audit_timeout + 40_000 -> :ok
            end

            cleanup(id, created, token, args, state)
            send(reply_alias, {ref, :released})

          {:error, message} ->
            send(reply_alias, {ref, {:error, message}})
        end
      after
        :global.del_lock(lock, [node()])
      end
    else
      send(reply_alias, {ref, {:error, "A Lighthouse audit is already running for this page."}})
    end
  end

  defp frontend(port, target) do
    with {:ok, result} <-
           Client.command(port, :browser, "Target.getDevToolsTarget", %{"targetId" => target}) do
      case result do
        %{"targetId" => id} ->
          {:ok, id, false}

        _ ->
          case Client.command(port, :browser, "Target.openDevTools", %{
                 "targetId" => target,
                 "panelId" => "lighthouse"
               }) do
            {:ok, %{"targetId" => id}} -> {:ok, id, true}
            {:error, message} -> {:error, message}
            _ -> {:error, "Chrome did not return a DevTools frontend target"}
          end
      end
    end
  end

  defp wait_frontend(port, id, deadline) do
    with {:ok, pages} <- Client.pages(port) do
      case Enum.find(pages, &(&1["id"] == id)) do
        %{"url" => url} ->
          case URI.new(url) do
            {:ok, %URI{scheme: "devtools", host: "devtools", path: "/bundled/" <> _}} -> :ok
            _ -> {:error, "Chrome returned an untrusted DevTools frontend"}
          end

        nil ->
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(50)
            wait_frontend(port, id, deadline)
          else
            {:error, "Chrome's DevTools frontend did not become available"}
          end
      end
    end
  end

  defp release({pid, reply_alias, ref}) do
    monitor = Process.monitor(pid)
    send(pid, {ref, :release})

    try do
      receive do
        {^ref, :released} -> :ok
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        35_000 -> :ok
      end
    after
      Process.unalias(reply_alias)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp cleanup(frontend, created, token, args, state) do
    expression =
      "(async()=>{if(location.protocol!=='devtools:'||location.host!=='devtools'||!location.pathname.startsWith('/bundled/'))return null;await globalThis.__backplaneLighthouseRuns?.get(#{Formata.JSON.encode!(token)})?.stop();return null})()"

    Client.command(state.port, frontend, "Runtime.evaluate", %{
      "expression" => expression,
      "awaitPromise" => true,
      "returnByValue" => true
    })

    target = state.pages[args["pageId"]]
    settings = Map.get(state, :emulations, %{})[target]
    observer = Map.get(state, :observers, %{})[target]

    try do
      if created,
        do: Client.command(state.port, :browser, "Target.closeTarget", %{"targetId" => frontend})
    after
      if settings != nil and is_pid(observer) and Process.alive?(observer) do
        if settings["viewport"],
          do: Observer.command(observer, "Emulation.clearDeviceMetricsOverride", %{})

        Diagnostics.restore_emulation(observer, settings)
      end
    end
  end

  defp audit(connection, options) do
    with :ok <-
           wait_ready(connection, options.targetId, System.monotonic_time(:millisecond) + 10_000),
         {:ok, value} <-
           evaluate(connection, "(#{@audit_script})(#{Formata.JSON.encode!(options)})") do
      {:ok, value}
    end
  end

  defp wait_ready(connection, target, deadline) do
    expression = "#{@ready_script}(#{Formata.JSON.encode!(target)})"

    case evaluate(connection, expression) do
      {:ok, true} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          wait_ready(connection, target, deadline)
        else
          {:error, "Chrome's DevTools frontend did not connect to the inspected page"}
        end
    end
  end

  defp evaluate(connection, expression) do
    case Client.send_command(connection, "Runtime.evaluate", %{
           "expression" => expression,
           "awaitPromise" => true,
           "returnByValue" => true
         }) do
      {:ok, %{"exceptionDetails" => details}} -> {:error, exception_message(details)}
      {:ok, %{"result" => %{"value" => value}}} -> {:ok, value}
      {:error, message} -> {:error, message}
      _ -> {:error, "Chrome returned an invalid Lighthouse response"}
    end
  end

  defp exception_message(%{"exception" => %{"description" => description}}),
    do: description |> String.split("\n") |> hd()

  defp exception_message(%{"text" => text}), do: text
  defp exception_message(_details), do: "Lighthouse audit failed."

  defp report_paths(nil) do
    with {:ok, prefix} <- Artifacts.destination(nil, ""),
         do: {:ok, [prefix <> ".json", prefix <> ".html"]}
  end

  defp report_paths(directory) do
    with {:ok, path} <- Artifacts.destination(Path.join(directory, "report"), ""),
         do: {:ok, [path <> ".json", path <> ".html"]}
  end

  defp finish({:ok, %{"lhr" => lhr, "html" => html} = report}, [json, html_path] = paths, state) do
    with {:ok, _} <- Artifacts.save(json, Formata.JSON.encode!(lhr)) do
      case Artifacts.save(html_path, html) do
        {:ok, _} ->
          report_result(lhr, report, paths, state)

        {:error, message} ->
          File.rm(json)
          {:error, message, state}
      end
    else
      {:error, message} -> {:error, message, state}
    end
  end

  defp finish({:error, message}, _paths, state), do: {:error, message, state}

  defp finish(_result, _paths, state),
    do: {:error, "Chrome returned an invalid Lighthouse report", state}

  defp report_result(%{"runtimeError" => error}, _report, paths, state) when is_map(error),
    do:
      {:error,
       "Lighthouse could not audit the page (#{error["code"]}): #{error["message"]} Reports: #{Enum.join(paths, ", ")}",
       state}

  defp report_result(_lhr, report, paths, state) do
    summary = report["summary"]

    scores =
      Enum.map(summary["scores"], fn score ->
        value = if score["score"] == nil, do: "n/a", else: round(score["score"] * 100)
        "- #{score["title"]}: #{value} (#{score["id"]})"
      end)

    lines =
      [
        "## Lighthouse audit results",
        "Mode: #{summary["mode"]}",
        "Device: #{summary["device"]}",
        "URL: #{summary["url"]}",
        "### Category scores"
      ] ++
        scores ++
        [
          "### Audit summary",
          "Passed: #{summary["audits"]["passed"]}",
          "Failed: #{summary["audits"]["failed"]}",
          "Total timing: #{summary["timing"]["total"]}ms"
        ]

    failed = report["failedAudits"]

    lines =
      lines ++
        if(failed == [],
          do: [],
          else: ["### Failed audits" | Enum.flat_map(failed, &audit_lines/1)]
        )

    lines = lines ++ ["### Reports" | Enum.map(paths, &"- #{&1}")]
    {:ok, [%{"type" => "text", "text" => Enum.join(lines, "\n")}], state}
  end

  defp audit_lines(audit) do
    category =
      if audit["categories"] == [], do: "", else: " [#{Enum.join(audit["categories"], ", ")}]"

    display = if audit["displayValue"], do: " (#{audit["displayValue"]})", else: ""

    heading =
      "- #{audit["id"]}#{category}: #{audit["title"]}#{display} (score: #{audit["score"]})"

    description = if audit["description"], do: ["  #{collapse(audit["description"])}"], else: []
    nodes = audit["nodes"]
    shown = if audit["totalNodes"] > length(nodes), do: ", showing #{length(nodes)}", else: ""

    label =
      if audit["totalNodes"] > 0, do: ["  Nodes (#{audit["totalNodes"]}#{shown}):"], else: []

    [heading] ++ description ++ label ++ Enum.flat_map(nodes, &node_lines/1)
  end

  defp node_lines(node) do
    fields = [{"selector", "selector"}, {"nodeLabel", "label"}, {"snippet", "snippet"}]

    line =
      Enum.flat_map(fields, fn {field, label} ->
        if node[field], do: ["#{label}=#{Formata.JSON.encode!(collapse(node[field]))}"], else: []
      end)
      |> Enum.join(" ")

    explanation = if node["explanation"], do: ["    #{collapse(node["explanation"])}"], else: []
    ["  - #{line}" | explanation]
  end

  defp collapse(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
