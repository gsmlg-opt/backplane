defmodule Backplane.CDP.MCP.Diagnostics do
  @moduledoc """
  Chrome DevTools MCP console, network summary, dialog and emulation tools.
  """

  alias Backplane.CDP.MCP.{Observer, Pages}
  @max_observers 16

  def ensure(target, state) do
    observers = Map.get(state, :observers, %{})
    pid = observers[target]

    cond do
      is_pid(pid) and Process.alive?(pid) ->
        {:ok, pid, state}

      map_size(observers) >= @max_observers ->
        {:error, "Too many observed browser pages in this MCP session", state}

      true ->
        case Observer.start(state.port, target) do
          {:ok, pid} -> {:ok, pid, Map.put(state, :observers, Map.put(observers, target, pid))}
          {:error, message} -> {:error, message, state}
        end
    end
  end

  def prune(state) do
    targets = MapSet.new(Map.values(state.pages))
    observers = Map.get(state, :observers, %{})

    Enum.each(observers, fn {target, pid} ->
      if not MapSet.member?(targets, target), do: Observer.stop(pid)
    end)

    state = Map.update(state, :emulations, %{}, &Map.take(&1, MapSet.to_list(targets)))

    Map.put(
      state,
      :observers,
      Map.filter(observers, fn {target, pid} ->
        MapSet.member?(targets, target) and Process.alive?(pid)
      end)
    )
  end

  def call(name, args, state) do
    with {:ok, target, state} <- Pages.selected(args, state),
         {:ok, pid, state} <- ensure(target, state),
         {:ok, data} <- Observer.data(pid) do
      execute(name, args, data, pid, state)
    else
      {:error, message, state} -> {:error, message, state}
      {:error, message} -> {:error, message, state}
    end
  end

  defp execute("list_console_messages", args, data, _pid, state) do
    messages =
      Enum.filter(data.console, fn entry ->
        preserved?(entry, data.generation, args["includePreservedMessages"]) and
          type?(entry.type, args["types"])
      end)

    {messages, pagination} = paginate(messages, args)
    lines = Enum.map(messages, &console_line(&1, args["includeStackTraces"]))
    result(state, "## Console messages", pagination, lines, "<no console messages found>")
  end

  defp execute("get_console_message", args, data, _pid, state) do
    case Enum.find(data.console, &(&1.id == args["msgid"])) do
      nil ->
        {:error, "Can't provide details for the msgid #{args["msgid"]}", state}

      message ->
        arguments =
          message.args
          |> Enum.with_index()
          |> Enum.map(fn {arg, index} -> "Arg ##{index}: #{arg}" end)

        parts = ["ID: #{message.id}", "Message: #{message.type}> #{message.text}"]
        parts = parts ++ if(arguments == [], do: [], else: ["### Arguments" | arguments])
        trace = format_stack(message.stack)
        parts = parts ++ if(trace == "", do: [], else: ["### Stack trace", trace])
        text(state, Enum.join(parts, "\n"))
    end
  end

  defp execute("list_network_requests", args, data, _pid, state) do
    requests =
      Enum.filter(data.network, fn entry ->
        preserved?(entry, data.generation, args["includePreservedRequests"]) and
          type?(entry.resource_type, args["resourceTypes"])
      end)

    {requests, pagination} = paginate(requests, args)
    lines = Enum.map(requests, &"reqid=#{&1.id} #{&1.method} #{&1.url} [#{&1.status}]")
    result(state, "## Network requests", pagination, lines, "No requests found.")
  end

  defp execute("get_network_request", args, data, _pid, state) do
    cond do
      Map.has_key?(args, "requestFilePath") or Map.has_key?(args, "responseFilePath") ->
        {:error, "Network body file output is unavailable because bodies are not collected.",
         state}

      args["reqid"] == nil ->
        text(state, "Nothing is currently selected in the DevTools Network panel.")

      true ->
        case Enum.find(data.network, &(&1.id == args["reqid"])) do
          nil ->
            {:error, "Can't provide details for the reqid #{args["reqid"]}", state}

          request ->
            text(
              state,
              "## Request #{request.url}\nStatus: #{request.status}\nMethod: #{request.method}\nResource type: #{request.resource_type}"
            )
        end
    end
  end

  defp execute("handle_dialog", args, data, pid, state) do
    if data.dialog == nil do
      {:error, "No open dialog found", state}
    else
      params = %{"accept" => args["action"] == "accept"}

      params =
        if args["promptText"], do: Map.put(params, "promptText", args["promptText"]), else: params

      case Observer.command(pid, "Page.handleJavaScriptDialog", params) do
        {:ok, _} ->
          action = if args["action"] == "accept", do: "accepted", else: "dismissed"
          text(state, "Successfully #{action} the dialog")

        {:error, message} ->
          {:error, message, state}
      end
    end
  end

  defp execute("emulate", args, _data, pid, state) do
    with :ok <- restore_emulation(pid, args) do
      target = state.pages[args["pageId"] || state.selected]
      previous = Map.get(state, :emulations, %{})[target] || %{}
      # Chrome keeps extra headers until explicitly replaced.
      settings = Map.merge(Map.take(previous, ["extraHttpHeaders"]), Map.delete(args, "pageId"))

      state =
        Map.update(state, :emulations, %{target => settings}, &Map.put(&1, target, settings))

      text(state, "Emulation configured successfully")
    else
      {:error, message} -> {:error, message, state}
    end
  end

  def restore_emulation(observer, settings) do
    with {:ok, commands} <- emulation_commands(settings) do
      Enum.reduce_while(commands, :ok, fn {method, params}, :ok ->
        case Observer.command(observer, method, params) do
          {:ok, _} -> {:cont, :ok}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
    end
  end

  defp preserved?(entry, generation, true), do: entry.generation >= generation - 2
  defp preserved?(entry, generation, _preserved), do: entry.generation == generation
  defp type?(_type, nil), do: true
  defp type?(_type, []), do: true
  defp type?(type, types), do: type in types

  defp result(state, heading, _pagination, [], empty), do: text(state, heading <> "\n" <> empty)

  defp result(state, heading, pagination, lines, _empty),
    do: text(state, Enum.join([heading | pagination ++ lines], "\n"))

  defp text(state, value), do: {:ok, [%{"type" => "text", "text" => value}], state}

  defp console_line(message, include_stack) do
    line = "msgid=#{message.id} [#{message.type}] #{message.text} (#{message.args_count} args)"
    stack = if include_stack, do: format_stack(message.stack), else: ""
    if stack == "", do: line, else: line <> "\n" <> stack
  end

  defp format_stack(frames) do
    Enum.map_join(frames, "\n", fn frame ->
      "#{frame["functionName"] || "<anonymous>"} (#{frame["url"]}:#{(frame["lineNumber"] || 0) + 1}:#{(frame["columnNumber"] || 0) + 1})"
    end)
  end

  defp paginate([], _args), do: {[], []}

  defp paginate(entries, args) do
    count = length(entries)
    size = args["pageSize"] || count
    pages = ceil(count / size)
    requested = if args["pageSize"], do: args["pageIdx"] || 0, else: 0
    invalid = requested >= pages
    current = if invalid, do: 0, else: requested
    first = current * size
    last = min(first + size, count)
    info = if invalid, do: ["Invalid page number provided. Showing first page."], else: []
    info = info ++ ["Showing #{first + 1}-#{last} of #{count} (Page #{current + 1} of #{pages})."]
    info = if current + 1 < pages, do: info ++ ["Next page: #{current + 1}"], else: info
    info = if current > 0, do: info ++ ["Previous page: #{current - 1}"], else: info
    {Enum.slice(entries, first, size), info}
  end

  defp emulation_commands(args) do
    with {:ok, geo} <- geolocation(args["geolocation"]),
         {:ok, viewport} <- viewport(args["viewport"]),
         {:ok, headers} <- headers(args),
         {:ok, network} <- network(args["networkConditions"]) do
      media =
        [
          {"colorScheme", "prefers-color-scheme"},
          {"forcedColors", "forced-colors"},
          {"prefersContrast", "prefers-contrast"},
          {"prefersReducedMotion", "prefers-reduced-motion"}
        ]
        |> Enum.map(fn {field, feature} ->
          value = args[field]
          %{"name" => feature, "value" => if(value in [nil, "auto"], do: "", else: value)}
        end)

      commands =
        [
          {"Network.emulateNetworkConditions", network},
          {"Emulation.setCPUThrottlingRate", %{"rate" => args["cpuThrottlingRate"] || 1}},
          geo,
          {"Emulation.setUserAgentOverride", %{"userAgent" => args["userAgent"] || ""}},
          {"Emulation.setEmulatedMedia", %{"features" => media}}
        ] ++ viewport ++ headers

      {:ok, commands}
    end
  end

  defp geolocation(nil), do: {:ok, {"Emulation.clearGeolocationOverride", %{}}}

  defp geolocation(value) do
    case String.split(value, ",") |> Enum.map(&Float.parse(String.trim(&1))) do
      [{lat, ""}, {lon, ""}] when lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180 ->
        {:ok,
         {"Emulation.setGeolocationOverride",
          %{"latitude" => lat, "longitude" => lon, "accuracy" => 1}}}

      _ ->
        {:error, "Invalid geolocation. Expected latitude,longitude."}
    end
  end

  defp viewport(nil),
    do:
      {:ok,
       [
         {"Emulation.clearDeviceMetricsOverride", %{}},
         {"Emulation.setTouchEmulationEnabled", %{"enabled" => false}}
       ]}

  defp viewport(value) do
    [dimensions | options] = String.split(value, ",")

    case String.split(dimensions, "x") do
      [width, height, scale] ->
        with {width, ""} <- Integer.parse(width),
             {height, ""} <- Integer.parse(height),
             {scale, ""} <- Float.parse(scale),
             true <- width > 0 and height > 0 and scale > 0,
             true <- Enum.all?(options, &(&1 in ~w(mobile touch landscape))) do
          orientation =
            if "landscape" in options,
              do: %{"type" => "landscapePrimary", "angle" => 90},
              else: %{"type" => "portraitPrimary", "angle" => 0}

          {:ok,
           [
             {"Emulation.setDeviceMetricsOverride",
              %{
                "width" => width,
                "height" => height,
                "deviceScaleFactor" => scale,
                "mobile" => "mobile" in options,
                "screenOrientation" => orientation
              }},
             {"Emulation.setTouchEmulationEnabled",
              %{"enabled" => "touch" in options or "mobile" in options}}
           ]}
        else
          _ ->
            {:error,
             "Invalid viewport. Expected widthxheightxdevicePixelRatio[,mobile][,touch][,landscape]."}
        end

      _ ->
        {:error,
         "Invalid viewport. Expected widthxheightxdevicePixelRatio[,mobile][,touch][,landscape]."}
    end
  end

  defp headers(args) when not is_map_key(args, "extraHttpHeaders"), do: {:ok, []}

  defp headers(%{"extraHttpHeaders" => ""}),
    do: {:ok, [{"Network.setExtraHTTPHeaders", %{"headers" => %{}}}]}

  defp headers(%{"extraHttpHeaders" => value}) do
    case Formata.JSON.decode(value) do
      {:ok, headers} when is_map(headers) ->
        if Enum.all?(headers, fn {_name, value} -> is_binary(value) end),
          do: {:ok, [{"Network.setExtraHTTPHeaders", %{"headers" => headers}}]},
          else: {:error, "Headers must have string values"}

      _ ->
        {:error, "Headers must be a JSON object"}
    end
  end

  defp network(nil),
    do:
      {:ok,
       %{"offline" => false, "latency" => 0, "downloadThroughput" => -1, "uploadThroughput" => -1}}

  defp network("Offline"),
    do:
      {:ok,
       %{"offline" => true, "latency" => 0, "downloadThroughput" => 0, "uploadThroughput" => 0}}

  defp network(name) do
    profiles = %{
      "Slow 3G" => {2_000, 50_000, 50_000},
      "Fast 3G" => {562.5, 180_000, 84_375},
      "Slow 4G" => {562.5, 180_000, 84_375},
      "Fast 4G" => {165, 1_012_500, 168_750}
    }

    case profiles[name] do
      {latency, down, up} ->
        {:ok,
         %{
           "offline" => false,
           "latency" => latency,
           "downloadThroughput" => down,
           "uploadThroughput" => up
         }}

      nil ->
        {:error, "Unknown network condition"}
    end
  end
end
