defmodule Backplane.CDP.MCP.Snapshot do
  @moduledoc "Accessibility snapshots and document-bound element UIDs."

  alias Backplane.CDP.Client

  def capture(connection, target, state, verbose \\ false) do
    with {:ok, %{"frameTree" => %{"frame" => frame}}} <-
           Client.send_command(connection, "Page.getFrameTree", %{}),
         {:ok, %{"nodes" => nodes}} when is_list(nodes) <-
           Client.send_command(connection, "Accessibility.getFullAXTree", %{}) do
      previous = Map.get(state.snapshots, target)
      generation = Map.get(state, :snapshot_sequence, 0) + 1
      nodes = root_url(nodes, frame["url"])
      {text, snapshot} = render(nodes, frame["loaderId"], previous, verbose, generation)

      state =
        state
        |> Map.put(:snapshot_sequence, generation)
        |> Map.put(:snapshots, Map.put(state.snapshots, target, snapshot))

      {:ok, "## Latest page snapshot\n" <> text, state}
    else
      {:error, message} -> {:error, message, state}
      _ -> {:error, "Chrome did not return an accessibility tree", state}
    end
  end

  def backend(target, state, uid) when is_binary(uid) do
    case get_in(state.snapshots, [target, :by_uid, uid]) do
      nil -> {:error, "Element with uid #{uid} was not found. Take a new snapshot."}
      node -> {:ok, node.backend_id}
    end
  end

  def backend(_target, _state, _uid), do: {:error, "A snapshot element uid is required"}

  def resolve(connection, target, state, uid) do
    with {:ok, backend_id} <- backend(target, state, uid),
         :ok <- current_document(connection, target, state),
         {:ok, %{"object" => %{"objectId" => object_id}}} <-
           Client.send_command(connection, "DOM.resolveNode", %{"backendNodeId" => backend_id}) do
      {:ok, object_id}
    else
      {:error, message} -> {:error, message}
      _ -> {:error, "The snapshot element is no longer available. Take a new snapshot."}
    end
  end

  def current_document(connection, target, state) do
    with %{loader_id: loader} <- state.snapshots[target],
         {:ok, %{"frameTree" => %{"frame" => %{"loaderId" => ^loader}}}} <-
           Client.send_command(connection, "Page.getFrameTree", %{}) do
      :ok
    else
      {:error, message} -> {:error, message}
      _ -> {:error, "The page changed since the last snapshot. Take a new snapshot."}
    end
  end

  @doc false
  def render(nodes, loader, previous, verbose, generation \\ nil) do
    generation = generation || if(previous, do: previous.generation + 1, else: 1)
    existing = if previous && previous.loader_id == loader, do: previous.by_backend, else: %{}

    {by_uid, by_backend, _next_index} =
      nodes
      |> Enum.reduce({%{}, %{}, 0}, fn node, {by_uid, by_backend, index} ->
        case node["backendDOMNodeId"] do
          backend when is_integer(backend) ->
            uid = Map.get(existing, backend, "#{generation}_#{index}")
            entry = %{backend_id: backend, role: value(node["role"]), name: value(node["name"])}
            {Map.put(by_uid, uid, entry), Map.put(by_backend, backend, uid), index + 1}

          _ ->
            {by_uid, by_backend, index}
        end
      end)

    indexed = Map.new(nodes, &{&1["nodeId"], &1})
    root = Enum.find(nodes, &(not Map.has_key?(&1, "parentId"))) || List.first(nodes)
    lines = if root, do: lines(root, indexed, by_backend, verbose, 0, MapSet.new()), else: []
    text = if lines == [], do: "", else: Enum.join(lines, "\n") <> "\n"
    {text, %{loader_id: loader, by_uid: by_uid, by_backend: by_backend, generation: generation}}
  end

  defp root_url(nodes, url) when is_binary(url) do
    Enum.map(nodes, fn node ->
      if Map.has_key?(node, "parentId") do
        node
      else
        property = %{"name" => "url", "value" => %{"value" => url}}

        Map.update(node, "properties", [property], fn properties ->
          Enum.reject(properties, &(&1["name"] == "url")) ++ [property]
        end)
      end
    end)
  end

  defp root_url(nodes, _url), do: nodes

  defp lines(node, indexed, uids, verbose, depth, visited) do
    id = node["nodeId"]

    if depth > 100 or MapSet.member?(visited, id) do
      []
    else
      visited = MapSet.put(visited, id)
      role = value(node["role"])
      interesting = node["ignored"] != true and role not in ["generic", "none"]
      show = role != "InlineTextBox" and (verbose or interesting)

      own =
        if show, do: [String.duplicate("  ", depth) <> format_node(node, uids, verbose)], else: []

      child_depth = if show, do: depth + 1, else: depth

      children =
        Enum.flat_map(node["childIds"] || [], fn child ->
          case indexed[child] do
            nil -> []
            node -> lines(node, indexed, uids, verbose, child_depth, visited)
          end
        end)

      own ++ children
    end
  end

  defp format_node(node, uids, verbose) do
    uid = uids[node["backendDOMNodeId"]]

    role =
      case value(node["role"]) do
        "StaticText" -> nil
        "none" -> "ignored"
        role -> role
      end

    name = value(node["name"])
    node_value = value(node["value"])

    properties =
      Enum.flat_map(node["properties"] || [], fn property ->
        name = property["name"]
        val = value(property["value"])

        cond do
          val == true -> [name]
          val == false -> []
          is_binary(val) or is_number(val) -> ["#{name}=#{Formata.JSON.encode!(val)}"]
          true -> []
        end
      end)

    parts = [
      if(uid, do: "uid=#{uid}"),
      role,
      if(name not in [nil, ""], do: Formata.JSON.encode!(name)),
      if(node_value != nil, do: "value=#{Formata.JSON.encode!(node_value)}")
    ]

    parts =
      if verbose and node["ignored"] and role != "ignored", do: parts ++ ["ignored"], else: parts

    (parts ++ properties) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
  end

  defp value(%{"value" => value}), do: value
  defp value(_), do: nil
end
