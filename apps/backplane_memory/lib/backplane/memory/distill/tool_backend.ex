defmodule Backplane.Memory.Distill.ToolBackend do
  @moduledoc """
  Agent-runtime tool backend for the background memory agent.

  Five tools act only on the memory domain: `read_chunk`, `search_memory`,
  `write_memory`, `replace_memory` and `forget_memory`. Model mistakes (unknown
  kind, a fact without subjects/property, source ids outside the chunk, ...) are
  returned as successful results whose text starts with `"error: "` so the model
  can correct itself; `{:error, %Backplane.AgentRuntime.Error{}}` is reserved for
  infrastructure failures.

  Writes carry `writer: "memory_agent"`, the session provenance and an idempotent
  `request_key` (`"distill:" <> subject_id <> ":" <> sha256(kind|subject_keys|property|content)`),
  so a retried run does not duplicate records. `backend_context.written` is a
  `:counters` ref counting newly inserted records and `backend_context.reads` one
  counting `read_chunk` calls.

  Destructive tools are narrowed against prompt injection: `forget_memory` needs
  `duplicate_of`, an active different record of the same kind, and neither
  `forget_memory` nor `replace_memory` touches a record written by the user.
  """

  import Ecto.Query, only: [from: 2]

  alias Backplane.AgentRuntime.Error
  alias Backplane.Memory.{Record, Records}

  @tool_names ~w(read_chunk search_memory write_memory replace_memory forget_memory)
  @write_kinds ~w(fact procedure worklog)
  @replaceable_kinds ~w(fact procedure)
  @search_limit 10

  @spec tool_names() :: [String.t()]
  def tool_names, do: @tool_names

  @doc "Builds the backend context for one chunk of `session`."
  @spec context(map(), [map()], String.t()) :: map()
  def context(session, chunk, mode) when mode in ["distill", "review"] do
    %{
      session: session,
      chunk: chunk,
      chunk_event_ids: MapSet.new(chunk, & &1["event_id"]),
      mode: mode,
      subject_id: field(session, :subject_id),
      written: :counters.new(1, []),
      reads: :counters.new(1, [])
    }
  end

  @doc "Agent-runtime tool descriptors bound to `context`."
  @spec descriptors(map()) :: [map()]
  def descriptors(context) do
    Enum.map(@tool_names, fn name ->
      {description, schema, safety} = spec(name)

      %{
        tool_name: name,
        tool_revision: 1,
        description: description,
        schema: schema,
        safety: safety,
        backend: __MODULE__,
        backend_context: context
      }
    end)
  end

  @spec execute(map()) :: {:ok, map()} | {:error, Error.t()}
  def execute(%{tool_name: name, backend_context: ctx} = operation) do
    name |> run(Map.get(operation, :arguments) || %{}, ctx) |> result()
  rescue
    exception ->
      {:error,
       Error.new(:execution_failure, "memory tool failed: " <> Exception.message(exception),
         details: %{tool: Map.get(operation, :tool_name)}
       )}
  end

  # -- tools ----------------------------------------------------------------

  defp run("read_chunk", _args, ctx) do
    :counters.add(ctx.reads, 1, 1)
    body = %{"observations" => ctx.chunk}

    body =
      if ctx.mode == "review" do
        written =
          Records.agent_written_for_session(
            field(ctx.session, :host_id),
            field(ctx.session, :session_id)
          )

        Map.put(body, "agent_written", Enum.map(written, &Records.to_map/1))
      else
        body
      end

    ok(body)
  end

  defp run("search_memory", args, _ctx) do
    with {:ok, query} <- required_string(args, "query"),
         {:ok, kind} <- optional_string(args, "kind"),
         {:ok, subject} <- optional_string(args, "subject") do
      filters =
        %{"limit" => @search_limit, "kind" => kind, "subject" => subject}
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      ok(%{"results" => query |> Records.search(filters) |> Enum.map(&Records.to_map/1)})
    end
  end

  defp run("write_memory", args, ctx) do
    with {:ok, attrs} <- record_attrs(args, ctx) do
      new? = not existing_request_key?(attrs["request_key"])

      case Records.remember(attrs) do
        {:ok, record} -> written(record, new?, ctx)
        {:error, changeset} -> invalid(changeset)
      end
    end
  end

  defp run("replace_memory", args, ctx) do
    with {:ok, id} <- required_string(args, "id"),
         {:ok, old} <- replaceable(id),
         {:ok, attrs} <- record_attrs(args, ctx),
         :ok <- same_kind(old, attrs) do
      new? = not existing_request_key?(attrs["request_key"])

      case Records.replace(old.id, attrs) do
        {:ok, record} -> written(record, new?, ctx)
        {:error, :not_found} -> error("memory #{id} not found")
        {:error, :not_active} -> error("memory #{id} is not active")
        {:error, :replacement_not_active} -> error("an identical memory was already removed")
        {:error, %Ecto.Changeset{} = changeset} -> invalid(changeset)
      end
    end
  end

  defp run("forget_memory", args, _ctx) do
    with {:ok, id} <- required_string(args, "id"),
         {:ok, reason} <- required_string(args, "reason"),
         {:ok, duplicate_of} <- required_string(args, "duplicate_of"),
         {:ok, target} <- forgettable(id),
         :ok <- duplicate(target, duplicate_of) do
      case Records.forget(target.id, reason) do
        {:ok, record} -> ok(Records.to_map(record))
        {:error, :not_found} -> error("memory #{id} not found")
      end
    end
  end

  defp run(name, _args, _ctx), do: error("unknown tool #{inspect(name)}")

  # -- write validation ---------------------------------------------------

  defp record_attrs(args, ctx) do
    with {:ok, kind} <- kind(args),
         {:ok, content} <- required_string(args, "content"),
         {:ok, title} <- optional_string(args, "title"),
         {:ok, property} <- optional_string(args, "property"),
         {:ok, tags} <- tags(args),
         {:ok, subjects, keys} <- subjects(args),
         :ok <- fact_slot(kind, keys, property),
         {:ok, ids} <- source_ids(args, ctx) do
      session = ctx.session

      {:ok,
       %{
         "kind" => kind,
         "content" => content,
         "title" => title,
         "subjects" => subjects,
         "property" => property,
         "tags" => tags,
         "writer" => "memory_agent",
         "host_id" => field(session, :host_id),
         "agent_id" => field(session, :agent_id),
         "integration" => field(session, :integration),
         "session_id" => field(session, :session_id),
         "source_event_ids" => ids,
         "observed_at" => observed_at(ids, ctx.chunk),
         "request_key" => request_key(ctx.subject_id, kind, keys, property, content)
       }}
    end
  end

  defp kind(args) do
    case args["kind"] do
      kind when kind in @write_kinds -> {:ok, kind}
      other -> error("kind must be one of fact, procedure, worklog (got #{inspect(other)})")
    end
  end

  defp subjects(args) do
    case Map.get(args, "subjects") do
      nil ->
        {:ok, [], []}

      list when is_list(list) ->
        if Enum.all?(list, &is_map/1) do
          {subjects, keys} = Records.normalize_subjects(list)
          {:ok, subjects, keys}
        else
          error("subjects must be a list of {type, key} objects")
        end

      _ ->
        error("subjects must be a list of {type, key} objects")
    end
  end

  defp fact_slot("fact", [], _property),
    do: error(~s(a fact needs non-empty subjects, e.g. [{"type": "repo", "key": "name"}]))

  defp fact_slot("fact", _keys, nil), do: error("a fact needs a non-empty property")
  defp fact_slot(_kind, _keys, _property), do: :ok

  defp tags(args) do
    case Map.get(args, "tags") do
      nil ->
        {:ok, []}

      tags when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1), do: {:ok, tags}, else: bad_tags()

      _ ->
        bad_tags()
    end
  end

  defp bad_tags, do: error("tags must be a list of strings")

  defp source_ids(args, ctx) do
    case Map.get(args, "source_event_ids") do
      [_ | _] = ids ->
        unknown = Enum.reject(ids, &(is_binary(&1) and MapSet.member?(ctx.chunk_event_ids, &1)))

        if unknown == [],
          do: {:ok, Enum.uniq(ids)},
          else:
            error(
              "source_event_ids must be event ids from the current chunk; unknown: " <>
                Enum.map_join(unknown, ", ", &inspect/1)
            )

      _ ->
        error("source_event_ids must be a non-empty list of event ids from the current chunk")
    end
  end

  defp forgettable(id) do
    case Records.get(id) do
      {:ok, %{record: %Record{writer: "user"}}} ->
        error("memory #{id} was written by the user and cannot be forgotten by the memory agent")

      {:ok, %{record: record}} ->
        {:ok, record}

      {:error, :not_found} ->
        error("memory #{id} not found")
    end
  end

  defp duplicate(%Record{id: id}, id),
    do: error("duplicate_of must be a different memory than the one being forgotten")

  defp duplicate(%Record{kind: kind}, duplicate_of) do
    case Records.get(duplicate_of) do
      {:ok, %{record: %Record{status: "active", kind: ^kind}}} ->
        :ok

      {:ok, %{record: %Record{status: "active", kind: other}}} ->
        error("duplicate_of #{duplicate_of} is a #{other}, not a #{kind}")

      {:ok, %{record: %Record{status: status}}} ->
        error("duplicate_of #{duplicate_of} is #{status}, not active")

      {:error, :not_found} ->
        error("duplicate_of #{duplicate_of} not found")
    end
  end

  defp replaceable(id) do
    case Records.get(id) do
      {:ok, %{record: %Record{writer: "user"}}} ->
        error("memory #{id} was written by the user and cannot be replaced by the memory agent")

      {:ok, %{record: %Record{status: "active", kind: kind} = record}}
      when kind in @replaceable_kinds ->
        {:ok, record}

      {:ok, %{record: %Record{status: "active", kind: kind}}} ->
        error("only an active procedure or fact can be replaced; memory #{id} is a #{kind}")

      {:ok, %{record: %Record{status: status}}} ->
        error("memory #{id} is #{status}, not active")

      {:error, :not_found} ->
        error("memory #{id} not found")
    end
  end

  defp same_kind(%Record{kind: kind}, %{"kind" => kind}), do: :ok

  defp same_kind(%Record{kind: old}, %{"kind" => new}),
    do: error("a #{old} can only be replaced by a #{old}, not a #{new}")

  defp observed_at(ids, chunk) do
    wanted = MapSet.new(ids)

    chunk
    |> Enum.filter(&MapSet.member?(wanted, &1["event_id"]))
    |> Enum.flat_map(fn obs ->
      case obs["at"] && DateTime.from_iso8601(obs["at"]) do
        {:ok, at, _} -> [at]
        _ -> []
      end
    end)
    |> Enum.max(DateTime, fn -> DateTime.utc_now() end)
  end

  @doc false
  def request_key(subject_id, kind, subject_keys, property, content) do
    digest =
      :crypto.hash(
        :sha256,
        kind <> "|" <> Enum.join(subject_keys, ",") <> "|" <> (property || "") <> "|" <> content
      )

    "distill:" <> to_string(subject_id) <> ":" <> Base.encode16(digest, case: :lower)
  end

  defp existing_request_key?(key),
    do: repo().exists?(from(r in Record, where: r.request_key == ^key))

  defp written(record, new?, ctx) do
    if new?, do: :counters.add(ctx.written, 1, 1)
    ok(Records.to_map(record))
  end

  defp invalid(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

    error("invalid memory: " <> details)
  end

  # -- argument helpers -----------------------------------------------------

  defp required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: error("#{key} is required"), else: {:ok, value}

      _ ->
        error("#{key} is required")
    end
  end

  defp optional_string(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, if(String.trim(value) == "", do: nil, else: value)}
      _ -> error("#{key} must be a string")
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp ok(body), do: {:ok, %{content: Jason.encode!(body)}}
  defp error(message), do: {:error_text, "error: " <> message}

  defp result({:error_text, text}), do: {:ok, %{content: text}}
  defp result(other), do: other

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  # -- tool specs -----------------------------------------------------------

  @read_only %{read_only: true, retry_safe: true, parallel_safe: true}

  @subjects_schema %{
    "type" => "array",
    "description" =>
      ~s(What the memory is about, e.g. [{"type": "repo", "key": "backplane"}, {"type": "host", "key": "web-01"}].),
    "items" => %{
      "type" => "object",
      "properties" => %{"type" => %{"type" => "string"}, "key" => %{"type" => "string"}},
      "required" => ["type", "key"]
    }
  }

  @write_properties %{
    "kind" => %{
      "type" => "string",
      "description" =>
        "fact (durable environment fact), procedure (reusable how-to) or worklog (one line per unit of work)."
    },
    "content" => %{"type" => "string", "description" => "The memory text."},
    "title" => %{"type" => "string"},
    "subjects" => @subjects_schema,
    "property" => %{
      "type" => "string",
      "description" => "Required for facts: the attribute of the subjects, e.g. \"path\"."
    },
    "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
    "source_event_ids" => %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "description" => "Event ids from the current chunk that support this memory."
    }
  }

  defp spec("read_chunk") do
    {"Read the observations of the session chunk being processed (in review mode also the memories the working agent already wrote for this session).",
     %{"type" => "object", "properties" => %{}}, @read_only}
  end

  defp spec("search_memory") do
    {"Search existing memory across all hosts. Always search before writing.",
     %{
       "type" => "object",
       "properties" => %{
         "query" => %{"type" => "string"},
         "kind" => %{"type" => "string", "description" => "fact, procedure or worklog."},
         "subject" => %{"type" => "string", "description" => "Subject key \"type:key\"."}
       },
       "required" => ["query"]
     }, @read_only}
  end

  defp spec("write_memory") do
    {"Store a new memory. Facts with the same subjects and property supersede older ones automatically.",
     %{
       "type" => "object",
       "properties" => @write_properties,
       "required" => ["kind", "content", "source_event_ids"]
     }, %{read_only: false, retry_safe: true, parallel_safe: false}}
  end

  defp spec("replace_memory") do
    {"Merge into an existing active procedure or fact: writes the new version and marks the old one superseded.",
     %{
       "type" => "object",
       "properties" =>
         Map.put(@write_properties, "id", %{
           "type" => "string",
           "description" => "Id of the memory being replaced."
         }),
       "required" => ["id", "kind", "content", "source_event_ids"]
     }, %{read_only: false, retry_safe: false, parallel_safe: false}}
  end

  defp spec("forget_memory") do
    {"Forget a memory that is an exact duplicate of another active memory of the same kind (duplicate_of). A reason is required.",
     %{
       "type" => "object",
       "properties" => %{
         "id" => %{"type" => "string", "description" => "Id of the duplicate to forget."},
         "reason" => %{"type" => "string"},
         "duplicate_of" => %{
           "type" => "string",
           "description" => "Id of the active memory that is kept and that this one duplicates."
         }
       },
       "required" => ["id", "reason", "duplicate_of"]
     }, %{read_only: false, retry_safe: true, parallel_safe: false}}
  end
end
