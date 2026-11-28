defmodule Backplane.CDP.MCP.TraceInsights do
  @moduledoc "Navigation-level DocumentLatency and DOMSize measurements from Chrome trace events."

  def build(bytes, frame) when byte_size(bytes) <= 16 * 1024 * 1024 do
    with {:ok, %{"traceEvents" => events}} <- Formata.JSON.decode(bytes) do
      events
      |> Enum.filter(&relevant?(&1, frame))
      |> Enum.sort_by(& &1["ts"])
      |> Enum.reduce(%{index: -1, id: nil, sets: %{}}, &measure/2)
      |> Map.fetch!(:sets)
    else
      _ -> %{}
    end
  end

  def build(_bytes, _frame), do: %{}

  def summary(sets) when map_size(sets) == 0,
    do: "No navigation insight sets were measured in this trace."

  def summary(sets) do
    lines =
      for {id, insights} <- Enum.sort(sets),
          do: "#{id}: " <> Enum.join(Enum.sort(Map.keys(insights)), ", ")

    Enum.join(["Available insight sets" | lines], "\n")
  end

  defp relevant?(%{"args" => args, "name" => name}, frame)
       when is_map(args) and name in ["navigationStart", "DOMStats", "ResourceReceiveResponse"],
       do: (args["frame"] || get_in(args, ["data", "frame"])) == frame

  defp relevant?(_, _), do: false

  defp measure(
         %{
           "name" => "navigationStart",
           "args" => %{"data" => %{"navigationId" => id, "documentLoaderURL" => url}}
         },
         acc
       )
       when is_binary(url) and url != "",
       do: %{acc | id: id, index: acc.index + 1}

  defp measure(
         %{
           "name" => "ResourceReceiveResponse",
           "args" => %{"data" => %{"requestId" => id, "timing" => timing}}
         },
         %{id: id} = acc
       ) do
    start = timing["sendEnd"]
    stop = timing["receiveHeadersStart"] || timing["receiveHeadersEnd"]

    if is_number(start) and is_number(stop) and start >= 0 and stop >= start do
      put(
        acc,
        "DocumentLatency",
        "Server response time: #{Float.round((stop - start) / 1, 2)} ms (request sent to first response headers)."
      )
    else
      acc
    end
  end

  defp measure(
         %{"name" => "DOMStats", "args" => %{"data" => %{"totalElements" => count} = dom}},
         acc
       ) do
    details = [
      "Total elements: #{count}",
      metric("Maximum depth", get_in(dom, ["maxDepth", "depth"])),
      metric("Maximum children", get_in(dom, ["maxChildren", "numChildren"]))
    ]

    put(acc, "DOMSize", details |> Enum.reject(&is_nil/1) |> Enum.join("\n"))
  end

  defp measure(_, acc), do: acc
  defp metric(name, value) when is_number(value), do: "#{name}: #{value}"
  defp metric(_, _), do: nil

  defp put(acc, key, value) do
    id = if acc.index < 0, do: "NO_NAVIGATION", else: "NAVIGATION_#{acc.index}"
    %{acc | sets: Map.update(acc.sets, id, %{key => value}, &Map.put(&1, key, value))}
  end
end
