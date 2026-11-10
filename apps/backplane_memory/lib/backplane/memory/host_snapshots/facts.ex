defmodule Backplane.Memory.HostSnapshots.Facts do
  @moduledoc """
  Pure validation and fact mapping for `host.snapshot.collected` payloads.

  Each snapshot item maps deterministically to zero or more fact descriptors;
  no LLM is involved.
  """

  alias Backplane.Memory.Records

  @key_fields %{
    "git" => "path",
    "docker" => "name",
    "systemd" => "name",
    "launchd" => "label",
    "host" => nil
  }

  @type fact :: %{
          subjects: [map()],
          subject_keys: [String.t()],
          property: String.t(),
          content: String.t(),
          slot: String.t()
        }

  @spec validate(map()) ::
          {:ok, %{collector: String.t(), unit: String.t(), complete: boolean(), items: [map()]}}
          | {:error, atom()}
  def validate(payload) when is_map(payload) do
    collector = payload["collector"]
    unit = payload["unit"]
    complete = payload["complete"]
    items = payload["items"]

    cond do
      not is_map_key(@key_fields, collector) -> {:error, :unknown_collector}
      not (is_binary(unit) and String.trim(unit) != "") -> {:error, :invalid_unit}
      not is_boolean(complete) -> {:error, :invalid_complete}
      not is_list(items) -> {:error, :invalid_items}
      not Enum.all?(items, &valid_item?(collector, &1)) -> {:error, :invalid_item}
      true -> {:ok, %{collector: collector, unit: unit, complete: complete, items: items}}
    end
  end

  def validate(_), do: {:error, :unknown_collector}

  @spec item_key(String.t(), map()) :: String.t()
  def item_key("host", _item), do: "host"
  def item_key(collector, item), do: Map.fetch!(item, Map.fetch!(@key_fields, collector))

  @spec facts(String.t(), String.t(), map()) :: [fact()]
  def facts(host_id, "git", item) do
    path = item["path"]
    repo = item["repository_id"]

    subjects =
      [{"host", host_id}, {"path", path}] ++ if(repo, do: [{"repo", repo}], else: [])

    checkout =
      "Git checkout of #{repo || "a local repository (no remote)"} at #{host_id}:#{path} " <>
        "(branch #{item["branch"] || "detached"})."

    [fact(subjects, "git_checkout", checkout)] ++ git_head(host_id, path, subjects, item["head"])
  end

  def facts(host_id, "docker", item) do
    ports = if item["ports"] in [nil, []], do: "none", else: Enum.join(item["ports"], ", ")

    content =
      "Docker container #{item["name"]} on #{host_id}: image #{item["image"]}, " <>
        "state #{item["state"]}, ports #{ports}."

    [fact([{"host", host_id}, {"service", item["name"]}], "docker_container", content)]
  end

  def facts(host_id, "systemd", item) do
    content = "systemd service #{item["name"]} runs on #{host_id}: #{item["description"]}."
    [fact([{"host", host_id}, {"service", item["name"]}], "systemd_service", content)]
  end

  def facts(host_id, "launchd", item) do
    content = "launchd job #{item["label"]} is loaded on #{host_id}."
    [fact([{"host", host_id}, {"service", item["label"]}], "launchd_job", content)]
  end

  def facts(host_id, "host", item) do
    subjects = [{"host", host_id}]

    ports =
      item["listening"]
      |> List.wrap()
      |> Enum.map_join(", ", fn l ->
        if l["process"], do: "#{l["port"]} (#{l["process"]})", else: "#{l["port"]}"
      end)

    [
      fact(subjects, "os", "#{host_id} runs #{item["os"]}."),
      fact(subjects, "hostname", "#{host_id} has hostname #{item["hostname"]}."),
      fact(
        subjects,
        "ip_addresses",
        "#{host_id} IP addresses: #{Enum.join(List.wrap(item["addresses"]), ", ")}."
      ),
      fact(subjects, "listening_ports", "#{host_id} listens on TCP ports: #{ports}.")
    ]
  end

  defp git_head(_host_id, _path, _subjects, nil), do: []

  defp git_head(host_id, path, subjects, head) do
    content =
      "Latest commit in #{host_id}:#{path}: #{String.slice(head["commit"], 0, 7)} " <>
        "\"#{head["subject"]}\" (#{head["committed_at"]})."

    [fact(subjects, "git_head", content)]
  end

  defp fact(subjects, property, content) do
    {normalized, keys} =
      subjects
      |> Enum.map(fn {type, key} -> %{"type" => type, "key" => key} end)
      |> Records.normalize_subjects()

    %{
      subjects: normalized,
      subject_keys: keys,
      property: property,
      content: content,
      slot: property <> "|" <> Enum.join(keys, ",")
    }
  end

  defp valid_item?("host", item), do: is_map(item)

  defp valid_item?(collector, item) when is_map(item) do
    case item[Map.fetch!(@key_fields, collector)] do
      key when is_binary(key) -> String.trim(key) != ""
      _ -> false
    end
  end

  defp valid_item?(_, _), do: false
end
