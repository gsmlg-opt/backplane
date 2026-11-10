defmodule Backplane.Memory.HostSnapshots.Facts do
  @moduledoc """
  Pure validation and fact mapping for `host.snapshot.collected` payloads.

  Each snapshot item maps deterministically to zero or more fact descriptors;
  no LLM is involved. Subjects always name the host by its id; content names it
  by the optional `host_label` (falling back to the id) so facts read naturally.
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

  @type snapshot :: %{
          collector: String.t(),
          unit: String.t(),
          complete: boolean(),
          items: [map()],
          host_label: String.t() | nil,
          unscanned: [String.t()]
        }

  @spec validate(map()) :: {:ok, snapshot()} | {:error, atom()}
  def validate(payload) when is_map(payload) do
    collector = payload["collector"]
    unit = payload["unit"]
    complete = payload["complete"]
    items = payload["items"]
    host_label = payload["host_label"]
    unscanned = Map.get(payload, "unscanned", [])

    cond do
      not is_map_key(@key_fields, collector) ->
        {:error, :unknown_collector}

      not non_blank?(unit) ->
        {:error, :invalid_unit}

      not is_boolean(complete) ->
        {:error, :invalid_complete}

      not is_list(items) ->
        {:error, :invalid_items}

      not Enum.all?(items, &valid_item?(collector, &1)) ->
        {:error, :invalid_item}

      not (is_nil(host_label) or non_blank?(host_label)) ->
        {:error, :invalid_host_label}

      not (is_list(unscanned) and Enum.all?(unscanned, &is_binary/1)) ->
        {:error, :invalid_unscanned}

      true ->
        {:ok,
         %{
           collector: collector,
           unit: unit,
           complete: complete,
           items: items,
           host_label: host_label,
           unscanned: Enum.sort(unscanned)
         }}
    end
  end

  def validate(_), do: {:error, :unknown_collector}

  @spec item_key(String.t(), map()) :: String.t()
  def item_key("host", _item), do: "host"
  def item_key(collector, item), do: Map.fetch!(item, Map.fetch!(@key_fields, collector))

  @doc """
  Maps one item to facts. `label` names the host in content (defaults to
  `host_id`); subjects and slots always use `host_id`.
  """
  @spec facts(String.t(), String.t(), map(), String.t() | nil) :: [fact()]
  def facts(host_id, collector, item, label \\ nil)

  def facts(host_id, "git", item, label) do
    name = label || host_id
    path = item["path"]
    repo = item["repository_id"]

    subjects =
      [{"host", host_id}, {"path", path}] ++ if(repo, do: [{"repo", repo}], else: [])

    checkout =
      "Git checkout of #{repo || "a local repository (no remote)"} at #{name}:#{path} " <>
        "(branch #{item["branch"] || "detached"})."

    [fact(subjects, "git_checkout", checkout)] ++ git_head(name, path, subjects, item["head"])
  end

  def facts(host_id, "docker", item, label) do
    ports = if item["ports"] in [nil, []], do: "none", else: Enum.join(item["ports"], ", ")

    content =
      "Docker container #{item["name"]} on #{label || host_id}: image #{item["image"]}, " <>
        "state #{item["state"]}, ports #{ports}."

    [fact([{"host", host_id}, {"service", item["name"]}], "docker_container", content)]
  end

  def facts(host_id, "systemd", item, label) do
    runs_on = "systemd service #{item["name"]} runs on #{label || host_id}"

    content =
      if non_blank?(item["description"]),
        do: "#{runs_on}: #{String.trim(item["description"])}.",
        else: runs_on <> "."

    [fact([{"host", host_id}, {"service", item["name"]}], "systemd_service", content)]
  end

  def facts(host_id, "launchd", item, label) do
    content = "launchd job #{item["label"]} is loaded on #{label || host_id}."
    [fact([{"host", host_id}, {"service", item["label"]}], "launchd_job", content)]
  end

  def facts(host_id, "host", item, label) do
    name = label || host_id
    subjects = [{"host", host_id}]

    [
      fact(subjects, "os", "#{name} runs #{item["os"]}."),
      fact(subjects, "hostname", "#{name} has hostname #{item["hostname"]}."),
      fact(
        subjects,
        "ip_addresses",
        "#{name} IP addresses: #{Enum.join(List.wrap(item["addresses"]), ", ")}."
      )
    ] ++ listening_ports(name, subjects, item)
  end

  # Absent on hosts where the collector cannot scan listening ports: no fact.
  defp listening_ports(_name, _subjects, item) when not is_map_key(item, "listening"), do: []

  defp listening_ports(name, subjects, item) do
    ports =
      item["listening"]
      |> List.wrap()
      |> Enum.map_join(", ", fn l ->
        if l["process"], do: "#{l["port"]} (#{l["process"]})", else: "#{l["port"]}"
      end)

    [fact(subjects, "listening_ports", "#{name} listens on TCP ports: #{ports}.")]
  end

  defp git_head(_name, _path, _subjects, nil), do: []

  defp git_head(name, path, subjects, head) do
    content =
      "Latest commit in #{name}:#{path}: #{String.slice(head["commit"], 0, 7)} " <>
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

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""
end
