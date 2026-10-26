defmodule Backplane.MemorySourceContract do
  @moduledoc "Pure validation and portable hashing for immutable external-source commands."

  @protocol "memory_sources.v1"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @hash ~r/\A[0-9a-f]{64}\z/
  @reserved ~w(host_id client_id source_client_id memory_space_id scope namespace partition requesting_actor authority_version access_id)
  @provenance ~w(session_id parent_session_id message_uid tool_call_uid tool_call_id role author repository_sources cwd write_origin execution_context)
  @openclaw_provenance ~w(run_id session_key occurrence_id document_path document_revision document_sha256 document_complete input_provenance message_index)
  @max_safe_integer 9_007_199_254_740_991
  @limits %{
    page_entries: 100,
    pages: 100,
    entries: 10_000,
    snapshot_bytes: 16_777_216,
    content_bytes: 262_144,
    page_bytes: 480_000
  }

  def protocol, do: @protocol
  def limits, do: @limits

  def validate(method, args) when is_map(args) and not is_struct(args) do
    with true <- Enum.all?(Map.keys(args), &is_binary/1),
         true <- not reserved?(args),
         true <- optional_uuid?(args, "memory_access_id"),
         true <- valid_source?(args["source"]),
         true <- valid_method?(method, Map.delete(args, "memory_access_id")),
         true <- args["source"]["integration"] != "openclaw" or safe_integers?(args),
         {:ok, json} <- encode(args),
         true <- byte_size(json) <= @limits.page_bytes do
      {:ok, args}
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  def validate(_, _), do: {:error, :invalid_arguments}

  def valid_source?(source) when is_map(source) and map_size(source) == 4 do
    uuid?(source["installation_id"]) and text?(source["profile_id"], 512) and
      case source["integration"] do
        "hermes" -> source["target"] in ~w(memory user)
        "openclaw" -> source["target"] in ~w(memory user provider)
        _ -> false
      end
  end

  def valid_source?(_), do: false

  defp valid_method?("source_status", args),
    do:
      keys?(args, ~w(source event_id), ~w(protocol)) and uuid?(args["event_id"]) and
        (not Map.has_key?(args, "protocol") or args["protocol"] == @protocol)

  defp valid_method?("source_mutate", args) do
    keys?(
      args,
      ~w(protocol source entry_id event_id revision operation type occurred_at provenance),
      ~w(content)
    ) and
      common?(args) and uuid?(args["entry_id"]) and positive?(args["revision"]) and
      args["type"] == "semantic" and
      provenance?(args["provenance"], args["source"]["integration"]) and
      timestamp?(args["occurred_at"]) and
      case args["operation"] do
        "upsert" ->
          text?(args["content"], @limits.content_bytes) and document?(args, args["source"])

        "withdraw" ->
          not Map.has_key?(args, "content")

        _ ->
          false
      end
  end

  defp valid_method?("source_reconcile", args) do
    common?(args) and uuid?(args["reconciliation_id"]) and
      case args["phase"] do
        "begin" ->
          keys?(
            args,
            ~w(protocol source event_id reconciliation_id phase revision page_count entry_count snapshot_hash),
            []
          ) and
            positive?(args["revision"]) and integer_range?(args["page_count"], 0, @limits.pages) and
            integer_range?(args["entry_count"], 0, @limits.entries) and
            hash?(args["snapshot_hash"]) and
            (args["page_count"] > 0 or args["entry_count"] == 0)

        "page" ->
          keys?(
            args,
            ~w(protocol source event_id reconciliation_id phase page_index page_hash entries),
            []
          ) and
            integer_range?(args["page_index"], 0, @limits.pages - 1) and hash?(args["page_hash"]) and
            is_list(args["entries"]) and length(args["entries"]) <= @limits.page_entries and
            Enum.all?(args["entries"], &valid_entry?(&1, args["source"])) and
            digest(args["entries"]) == args["page_hash"]

        "commit" ->
          keys?(args, ~w(protocol source event_id reconciliation_id phase complete), []) and
            args["complete"] == true

        "abort" ->
          keys?(args, ~w(protocol source event_id reconciliation_id phase), [])

        _ ->
          false
      end
  end

  defp valid_method?(_, _), do: false
  defp common?(args), do: args["protocol"] == @protocol and uuid?(args["event_id"])

  defp valid_entry?(entry, source) when is_map(entry),
    do:
      keys?(entry, ~w(entry_id content type provenance), []) and uuid?(entry["entry_id"]) and
        text?(entry["content"], @limits.content_bytes) and entry["type"] == "semantic" and
        provenance?(entry["provenance"], source["integration"]) and document?(entry, source)

  defp valid_entry?(_, _), do: false

  defp provenance?(value, integration) when is_map(value) do
    allowed =
      if integration == "openclaw", do: @provenance ++ @openclaw_provenance, else: @provenance

    Map.keys(value) -- allowed == [] and not reserved?(value) and
      Enum.all?(value, fn
        {"document_complete", complete} ->
          is_boolean(complete)

        {"message_index", index} ->
          integer_range?(index, 0, @max_safe_integer)

        {key, hash} when key in ~w(document_revision document_sha256) ->
          hash?(hash)

        {"document_path", path} ->
          path in ~w(USER.md MEMORY.md)

        {"input_provenance", input} ->
          is_map(input) and match?({:ok, _}, encode(input))

        {"author", author} ->
          is_map(author) and match?({:ok, _}, encode(author))

        {"repository_sources", sources} ->
          is_list(sources) and length(sources) <= 32 and Enum.all?(sources, &is_map/1)

        {"role", role} ->
          role in ~w(user assistant tool operator system)

        {_, text} ->
          text?(text, 4096)
      end)
  end

  defp provenance?(_, _), do: false

  defp document?(entry, %{"integration" => "openclaw", "target" => target}) do
    provenance = entry["provenance"]

    if target == "provider" do
      Map.keys(provenance) --
        ~w(document_path document_revision document_sha256 document_complete) ==
        Map.keys(provenance)
    else
      expected_path = if target == "user", do: "USER.md", else: "MEMORY.md"
      digest = :crypto.hash(:sha256, entry["content"]) |> Base.encode16(case: :lower)

      provenance["document_path"] == expected_path and provenance["document_complete"] == true and
        provenance["document_sha256"] == digest and provenance["document_revision"] == digest
    end
  end

  defp document?(_, _), do: true

  defp safe_integers?(value) when is_integer(value), do: abs(value) <= @max_safe_integer

  defp safe_integers?(value) when is_map(value),
    do: Enum.all?(value, fn {_, item} -> safe_integers?(item) end)

  defp safe_integers?(value) when is_list(value), do: Enum.all?(value, &safe_integers?/1)
  defp safe_integers?(_), do: true

  defp reserved?(map) when is_map(map),
    do: Enum.any?(map, fn {key, value} -> key in @reserved or reserved?(value) end)

  defp reserved?(list) when is_list(list), do: Enum.any?(list, &reserved?/1)
  defp reserved?(_), do: false

  defp keys?(map, required, optional),
    do:
      Enum.all?(required, &Map.has_key?(map, &1)) and
        Map.keys(map) -- (required ++ optional) == []

  defp optional_uuid?(map, key), do: not Map.has_key?(map, key) or uuid?(map[key])
  def uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
  defp hash?(value), do: is_binary(value) and Regex.match?(@hash, value)

  defp positive?(value),
    do: is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807

  defp integer_range?(value, low, high), do: is_integer(value) and value >= low and value <= high

  defp text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..max and
        String.trim(value) != "" and not String.contains?(value, <<0>>)

  defp timestamp?(value),
    do: is_binary(value) and match?({:ok, _, _}, DateTime.from_iso8601(value))

  @doc "SHA256 of sorted-key compact UTF8 JSON; strings and integers are portable across peers."
  def digest(value) do
    case encode(value) do
      {:ok, encoded} -> :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  def encode(value) do
    case canonical(value) do
      {:ok, io} -> {:ok, IO.iodata_to_binary(io)}
      error -> error
    end
  rescue
    _ -> {:error, :not_json_safe}
  end

  defp canonical(map) when is_map(map) and not is_struct(map) do
    if Enum.all?(Map.keys(map), &(is_binary(&1) and String.valid?(&1))) do
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
        case canonical(value) do
          {:ok, encoded} -> {:cont, {:ok, [[JSON.encode!(key), ?:, encoded] | acc]}}
          error -> {:halt, error}
        end
      end)
      |> wrap(?{, ?})
    else
      {:error, :not_json_safe}
    end
  end

  defp canonical(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case canonical(value) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> wrap(?[, ?])
  end

  defp canonical(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: {:ok, JSON.encode!(value)}

  defp canonical(_), do: {:error, :not_json_safe}

  defp wrap({:ok, parts}, left, right),
    do: {:ok, [left, Enum.intersperse(Enum.reverse(parts), ?,), right]}

  defp wrap(error, _, _), do: error
end
