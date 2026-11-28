defmodule Backplane.CDP.MCP.Styles do
  @moduledoc false
  alias Backplane.CDP.Client
  alias Backplane.CDP.MCP.{Pages, Snapshot}

  def call("get_css_styles", args, state) do
    with {:ok, target, state} <- Pages.selected(args, state) do
      case Client.with_connection(state.port, target, &inspect_styles(&1, target, args, state)) do
        {:ok, text} -> {:ok, [%{"type" => "text", "text" => text}], state}
        {:error, msg} -> {:error, msg, state}
      end
    end
  end

  defp inspect_styles(conn, target, args, state) do
    with {:ok, backend} <- Snapshot.backend(target, state, args["uid"]),
         :ok <- Snapshot.current_document(conn, target, state),
         {:ok, _} <- Client.send_command(conn, "DOM.enable", %{}),
         {:ok, _} <- Client.send_command(conn, "CSS.enable", %{}),
         {:ok, _} <- Client.send_command(conn, "DOM.getDocument", %{"depth" => 0}),
         {:ok, %{"nodeIds" => [id]}} when id > 0 <-
           Client.send_command(conn, "DOM.pushNodesByBackendIdsToFrontend", %{
             "backendNodeIds" => [backend]
           }),
         {:ok, matched} <-
           Client.send_command(conn, "CSS.getMatchedStylesForNode", %{"nodeId" => id}),
         {:ok, %{"computedStyle" => computed}} <-
           Client.send_command(conn, "CSS.getComputedStyleForNode", %{"nodeId" => id}) do
      {:ok, format(matched, computed, args)}
    else
      {:error, _} = error -> error
      _ -> {:error, "The snapshot element is no longer available. Take a new snapshot."}
    end
  end

  defp format(matched, computed, args) do
    elements = [matched | Map.get(matched, "inherited", [])]

    rules =
      for {element, depth} <- Enum.with_index(elements),
          {selector, properties} <- rules(element),
          properties != [],
          do: {selector, properties, depth}

    names =
      rules
      |> Enum.flat_map(fn {_, props, _} -> Enum.map(props, & &1["name"]) end)
      |> MapSet.new()

    names =
      MapSet.union(
        names,
        MapSet.new(~w(display width height) ++ Map.get(args, "computedProperties", []))
      )

    computed = Enum.filter(computed, &MapSet.member?(names, &1["name"]))
    entries = [block("Computed styles", computed) | Enum.map(rules, &format_rule/1)]
    total = length(entries)
    size = Map.get(args, "pageSize", 10)
    requested = Map.get(args, "pageIdx", 0)
    pages = div(total + size - 1, size)
    page = if requested < pages, do: requested, else: 0

    range =
      "Showing #{page * size + 1}-#{min(total, (page + 1) * size)} of #{total} (Page #{page + 1} of #{pages})."

    Enum.join([range | Enum.slice(entries, page * size, size)], "\n")
  end

  defp rules(element) do
    inline = [{"element.style", get_in(element, ["inlineStyle", "cssProperties"]) || []}]

    inline ++
      Enum.map(Enum.reverse(Map.get(element, "matchedCSSRules", [])), fn %{"rule" => rule} ->
        {get_in(rule, ["selectorList", "text"]), get_in(rule, ["style", "cssProperties"]) || []}
      end)
  end

  defp format_rule({selector, props, depth}) do
    prefix = if depth > 0, do: "Inherited (#{depth}): ", else: ""
    block(prefix <> selector, Enum.reject(props, &(&1["disabled"] == true)))
  end

  defp block(label, props) do
    body = Enum.map_join(props, "\n", fn prop -> "  #{prop["name"]}: #{prop["value"]};" end)
    "#{label} {\n#{body}\n}"
  end
end
