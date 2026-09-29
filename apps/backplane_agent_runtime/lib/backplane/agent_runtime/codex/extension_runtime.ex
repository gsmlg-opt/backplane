defmodule Backplane.AgentRuntime.Codex.ExtensionRuntime do
  @moduledoc """
  Owner-bound runtime for the pinned Codex stateful extension tools.

  The bundled backend is intentionally ephemeral. Hosts that require durable
  state provide an adapter at process start; adapter selection and scope never
  come from model arguments.
  """

  use GenServer

  alias Backplane.AgentRuntime.Error

  @memory_names ~w(add_ad_hoc_note list read search)
  @goal_names ~w(get_goal create_goal update_goal)
  @skill_names ~w(list read)
  @history_names ~w(list_windows list_items read_item search_contents)
  @note_names ~w(list_files_by_prefix read_file search_contents append_to_file write_file)
  @board_names ~w(create_channel get_channels list_threads search_posts read_thread read_post subscribe unsubscribe post)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @spec contracts(map()) :: [map()]
  def contracts(%{extension_runtime: runtime}) when is_pid(runtime) do
    %{board_namespace: board_namespace} = GenServer.call(runtime, :capabilities)

    Enum.concat([
      Enum.map(@goal_names, &contract(nil, &1, runtime)),
      Enum.map(@memory_names, &contract("memories", &1, runtime)),
      Enum.map(@skill_names, &contract("skills", &1, runtime)),
      Enum.map(@history_names, &contract("history", &1, runtime)),
      Enum.map(@note_names, &contract("notes", &1, runtime)),
      Enum.map(@board_names, &contract(board_namespace, &1, runtime))
    ])
  end

  def contracts(_context), do: []

  @spec call(map()) :: {:ok, map()} | {:error, Error.t()}
  def call(%{backend_context: %{runtime: runtime}} = operation) when is_pid(runtime),
    do: GenServer.call(runtime, {:tool, operation}, :infinity)

  def call(_operation),
    do: {:error, Error.new(:unsupported_capability, "extension runtime is unavailable")}

  @impl true
  def init(opts) do
    with {:ok, scope} <- validate_scope(Keyword.get(opts, :scope, %{})),
         {:ok, board_namespace} <-
           board_namespace(Keyword.get(opts, :board_namespace, "collaboration")),
         :ok <- validate_adapter(Keyword.get(opts, :adapter)),
         {:ok, owner_monitor} <- monitor_owner(Keyword.get(opts, :owner_pid)) do
      {:ok,
       %{
         scope: scope,
         owner_monitor: owner_monitor,
         board_namespace: board_namespace,
         adapter: Keyword.get(opts, :adapter),
         adapter_context: Keyword.get(opts, :adapter_context, %{}),
         reference: reference_state(opts)
       }}
    end
  end

  @impl true
  def handle_call(:capabilities, _from, state) do
    {:reply,
     %{
       mode: if(state.adapter, do: :host, else: :ephemeral_reference),
       durable: not is_nil(state.adapter),
       board_namespace: state.board_namespace
     }, state}
  end

  def handle_call({:tool, operation}, _from, state) do
    with :ok <- owner_check(state.scope, operation),
         :ok <- known_tool(operation.tool_name, state.board_namespace) do
      case execute(state, operation) do
        {:ok, result, next} -> {:reply, {:ok, result}, next}
        {:error, %Error{} = error} -> {:reply, {:error, error}, state}
      end
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state),
    do: {:stop, :normal, state}

  defp execute(%{adapter: adapter} = state, operation)
       when is_atom(adapter) and not is_nil(adapter) do
    case adapter.execute(operation, state.scope, state.adapter_context) do
      {:ok, result} when is_map(result) -> {:ok, result, state}
      {:error, %Error{} = error} -> {:error, error}
      other -> {:error, malformed("extension adapter returned invalid data", other)}
    end
  end

  defp execute(state, operation) do
    case reference_execute(state.reference, operation.tool_name, operation.arguments, state) do
      {:ok, result, reference} -> {:ok, result, %{state | reference: reference}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp reference_execute(reference, "get_goal", _arguments, _state),
    do: {:ok, goal_response(reference.goal), reference}

  defp reference_execute(reference, "create_goal", arguments, _state) do
    with {:ok, objective} <- required_string(arguments, "objective"),
         :ok <- no_unfinished_goal(reference.goal),
         {:ok, token_budget} <- optional_positive_integer(arguments, "token_budget") do
      goal = %{
        id: unique_id("goal"),
        objective: String.trim(objective),
        status: "active",
        token_budget: token_budget,
        created_at_ms: now_ms(),
        updated_at_ms: now_ms()
      }

      {:ok, goal_response(goal), %{reference | goal: goal}}
    end
  end

  defp reference_execute(reference, "update_goal", arguments, _state) do
    with {:ok, goal} <- present(reference.goal, "no goal exists"),
         {:ok, status} <- required_string(arguments, "status"),
         :ok <- allowed(status, ~w(complete blocked paused), "invalid goal status") do
      goal = %{goal | status: status, updated_at_ms: now_ms()}
      {:ok, goal_response(goal), %{reference | goal: goal}}
    end
  end

  defp reference_execute(reference, "memories::add_ad_hoc_note", arguments, _state) do
    with {:ok, filename} <- required_string(arguments, "filename"),
         {:ok, note} <- required_string(arguments, "note"),
         :ok <- memory_filename(filename),
         :ok <- absent(reference.memories, filename, "ad-hoc note already exists") do
      memories = Map.put(reference.memories, filename, note)
      {:ok, %{path: filename, bytes: byte_size(note)}, %{reference | memories: memories}}
    end
  end

  defp reference_execute(reference, "memories::list", arguments, _state) do
    prefix = Map.get(arguments, "path", "")
    limit = bounded_limit(arguments["max_results"], 2_000)
    offset = cursor_offset(arguments["cursor"])

    items =
      reference.memories
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    {page, next_cursor} = page(items, offset, limit)
    {:ok, %{items: page, next_cursor: next_cursor, truncated: not is_nil(next_cursor)}, reference}
  end

  defp reference_execute(reference, "memories::read", arguments, _state) do
    with {:ok, path} <- required_string(arguments, "path"),
         {:ok, contents} <- fetch(reference.memories, path, "memory not found") do
      offset = max(Map.get(arguments, "line_offset", 1) - 1, 0)
      max_lines = Map.get(arguments, "max_lines")
      lines = String.split(contents, "\n", trim: false) |> Enum.drop(offset)
      lines = if is_integer(max_lines), do: Enum.take(lines, max_lines), else: lines
      value = Enum.join(lines, "\n")

      {:ok, %{path: path, contents: value, truncated: byte_size(value) < byte_size(contents)},
       reference}
    end
  end

  defp reference_execute(reference, "memories::search", arguments, _state) do
    queries = Map.get(arguments, "queries", [])
    mode = Map.get(arguments, "match_mode", "any")
    sensitive? = Map.get(arguments, "case_sensitive", true)
    prefix = Map.get(arguments, "path", "")
    limit = bounded_limit(arguments["max_results"], 200)
    offset = cursor_offset(arguments["cursor"])

    with :ok <- nonempty_strings(queries, "queries are required"),
         :ok <- allowed(mode, ~w(any all), "invalid match mode") do
      matches =
        reference.memories
        |> Enum.filter(fn {path, _} -> String.starts_with?(path, prefix) end)
        |> Enum.flat_map(fn {path, contents} ->
          contents
          |> String.split("\n", trim: false)
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _line_number} -> matches?(line, queries, mode, sensitive?) end)
          |> Enum.map(fn {line, line_number} ->
            %{path: path, line_number: line_number, line: line}
          end)
        end)
        |> Enum.sort_by(&{&1.path, &1.line_number})

      {page, next_cursor} = page(matches, offset, limit)

      {:ok, %{matches: page, next_cursor: next_cursor, truncated: not is_nil(next_cursor)},
       reference}
    end
  end

  defp reference_execute(reference, "skills::list", arguments, _state) do
    authority = Map.get(arguments, "authority")
    offset = cursor_offset(arguments["cursor"])

    skills =
      reference.skills
      |> Enum.filter(&authority_matches?(&1, authority))
      |> Enum.sort_by(&{Map.get(&1, :package), Map.get(&1, :name)})

    {page, next_cursor} = page(skills, offset, 20)
    listed = Enum.map(page, &Map.drop(&1, [:contents, :resources]))
    {:ok, %{skills: listed, warnings: [], next_cursor: next_cursor}, reference}
  end

  defp reference_execute(reference, "skills::read", arguments, _state) do
    with {:ok, package} <- required_string(arguments, "package"),
         {:ok, skill} <- find_skill(reference.skills, package),
         resource = Map.get(arguments, "resource", Map.get(skill, :main_resource, "SKILL.md")),
         {:ok, contents} <- skill_resource(skill, resource) do
      {:ok,
       %{
         resource: resource,
         contents: contents,
         skill_root: Map.get(skill, :skill_root),
         next_cursor: nil
       }, reference}
    end
  end

  defp reference_execute(reference, "history::list_windows", arguments, _state) do
    windows =
      reference.history
      |> Enum.group_by(&Map.get(&1, :window_id, "window-1"))
      |> Enum.map(fn {window_id, items} -> %{window_id: window_id, item_count: length(items)} end)
      |> maybe_reverse(Map.get(arguments, "recent_first", false))
      |> Enum.take(bounded_limit(arguments["limit"], 100))

    {:ok, %{windows: windows}, reference}
  end

  defp reference_execute(reference, "history::list_items", arguments, _state) do
    items = filter_history(reference.history, arguments)
    limit = bounded_limit(arguments["limit"], 100)
    max_chars = bounded_limit(arguments["max_chars_per_item"], 1_000)

    items =
      items
      |> maybe_reverse(Map.get(arguments, "recent_first", false))
      |> Enum.take(limit)
      |> Enum.map(
        &Map.put(&1, :truncated_content, truncate(Map.get(&1, :content, ""), max_chars))
      )

    {:ok, %{items: items}, reference}
  end

  defp reference_execute(reference, "history::read_item", arguments, _state) do
    with {:ok, window_id} <- required_string(arguments, "window_id"),
         {:ok, item_id} <- required_string(arguments, "item_id"),
         {:ok, item} <-
           Enum.find(
             reference.history,
             &(Map.get(&1, :window_id) == window_id and Map.get(&1, :id) == item_id)
           )
           |> present("history item not found") do
      content = Map.get(item, :content, "")
      offset = Map.get(arguments, "offset_chars", 0)
      limit = bounded_limit(arguments["limit_chars"], 20_000)
      slice = String.slice(content, offset, limit)

      {:ok, %{item: item, content: slice, next_offset_chars: offset + String.length(slice)},
       reference}
    end
  end

  defp reference_execute(reference, "history::search_contents", arguments, _state) do
    with {:ok, query} <- required_string(arguments, "query") do
      matches =
        reference.history
        |> filter_history(arguments)
        |> Enum.filter(&String.contains?(Map.get(&1, :content, ""), query))
        |> maybe_reverse(Map.get(arguments, "recent_first", false))
        |> Enum.take(bounded_limit(arguments["limit"], 100))

      {:ok, %{items: matches}, reference}
    end
  end

  defp reference_execute(reference, "notes::write_file", arguments, _state),
    do: write_note(reference, arguments, :write)

  defp reference_execute(reference, "notes::append_to_file", arguments, _state),
    do: write_note(reference, arguments, :append)

  defp reference_execute(reference, "notes::read_file", arguments, _state) do
    with {:ok, path} <- required_string(arguments, "path"),
         :ok <- safe_virtual_path(path),
         {:ok, note} <- fetch(reference.notes, path, "note not found") do
      lines = String.split(note.text, "\n", trim: false)
      selected = line_range(lines, arguments["start_line"], arguments["stop_line"])
      {:ok, %{path: path, contents: Enum.join(selected, "\n"), n_lines: length(lines)}, reference}
    end
  end

  defp reference_execute(reference, "notes::list_files_by_prefix", arguments, _state) do
    prefix = Map.get(arguments, "prefix") || ""
    limit = bounded_limit(arguments["max_results"], 100)
    desc? = Map.get(arguments, "file_order", "ascending") == "descending"

    with {:ok, order_by} <- note_order_field(Map.get(arguments, "file_order_by", "name")) do
      files =
        reference.notes
        |> Enum.filter(fn {path, _} -> String.starts_with?(path, prefix) end)
        |> Enum.map(fn {path, note} -> Map.merge(Map.drop(note, [:text]), %{path: path}) end)
        |> Enum.sort_by(&Map.fetch!(&1, order_by), :asc)
        |> maybe_reverse(desc?)
        |> Enum.take(limit)

      {:ok, %{files: files}, reference}
    end
  end

  defp reference_execute(reference, "notes::search_contents", arguments, _state) do
    with {:ok, query} <- required_string(arguments, "query") do
      prefix = Map.get(arguments, "path_prefix") || ""
      max_files = bounded_limit(arguments["max_files"], 100)
      max_matches = bounded_limit(arguments["max_matches_per_file"], 20)

      files =
        reference.notes
        |> Enum.filter(fn {path, _} -> String.starts_with?(path, prefix) end)
        |> Enum.flat_map(fn {path, note} ->
          matches =
            note.text
            |> String.split("\n", trim: false)
            |> Enum.with_index(1)
            |> Enum.filter(fn {line, _} -> String.contains?(line, query) end)
            |> Enum.take(max_matches)
            |> Enum.map(fn {line, line_number} -> %{line: line, line_number: line_number} end)

          if matches == [], do: [], else: [%{path: path, matches: matches}]
        end)
        |> maybe_reverse(Map.get(arguments, "recent_file_first", false))
        |> Enum.take(max_files)

      {:ok, %{files: files}, reference}
    end
  end

  defp reference_execute(reference, tool_name, arguments, state) do
    prefix = state.board_namespace <> "::"
    action = String.replace_prefix(tool_name, prefix, "")

    if String.starts_with?(tool_name, prefix) and action in @board_names,
      do: board_execute(reference, action, arguments, state),
      else: {:error, Error.new(:not_found, "unknown extension tool")}
  end

  defp board_execute(reference, "create_channel", arguments, _state) do
    with {:ok, name} <- required_string(arguments, "channel_name"),
         :ok <- absent(reference.channels, name, "channel already exists") do
      channel = %{name: name, created_at_ms: now_ms(), updated_at_ms: now_ms()}

      subscriptions =
        maybe_subscribe(
          reference.subscriptions,
          {:channel, name},
          arguments["subscribe"] != false
        )

      {:ok, %{channel: channel},
       %{
         reference
         | channels: Map.put(reference.channels, name, channel),
           subscriptions: subscriptions
       }}
    end
  end

  defp board_execute(reference, "get_channels", arguments, _state) do
    query = String.downcase(Map.get(arguments, "query", ""))

    channels =
      reference.channels
      |> Map.values()
      |> Enum.filter(&String.contains?(String.downcase(&1.name), query))
      |> Enum.sort_by(& &1.updated_at_ms, :desc)
      |> Enum.take(bounded_limit(arguments["limit"], 20))

    {:ok, %{channels: channels, next_cursor: nil}, reference}
  end

  defp board_execute(reference, "post", arguments, _state) do
    with {:ok, text} <- required_string(arguments, "text"),
         {:ok, destination} <- board_destination(arguments),
         {:ok, reference, channel, thread_id} <- ensure_destination(reference, destination) do
      id = unique_id("post")

      post = %{
        id: id,
        thread_id: thread_id || id,
        channel_name: channel,
        text: text,
        created_at_ms: now_ms()
      }

      posts = Map.put(reference.posts, id, post)
      subscriptions = MapSet.put(reference.subscriptions, {:thread, post.thread_id})
      channels = Map.update!(reference.channels, channel, &%{&1 | updated_at_ms: now_ms()})

      {:ok, Map.drop(post, [:text]),
       %{reference | posts: posts, subscriptions: subscriptions, channels: channels}}
    end
  end

  defp board_execute(reference, "list_threads", arguments, _state) do
    with {:ok, channel} <- required_string(arguments, "channel_name") do
      threads =
        reference.posts
        |> Map.values()
        |> Enum.filter(&(&1.channel_name == channel and &1.id == &1.thread_id))
        |> Enum.sort_by(& &1.created_at_ms, :desc)
        |> Enum.take(bounded_limit(arguments["limit"], 20))

      {:ok, %{threads: threads, next_cursor: nil}, reference}
    end
  end

  defp board_execute(reference, "search_posts", arguments, _state) do
    query = String.downcase(Map.get(arguments, "query", ""))
    channel = Map.get(arguments, "channel_name")

    posts =
      reference.posts
      |> Map.values()
      |> Enum.filter(&(is_nil(channel) or &1.channel_name == channel))
      |> Enum.filter(&String.contains?(String.downcase(&1.text), query))
      |> Enum.sort_by(& &1.created_at_ms, :desc)
      |> Enum.take(bounded_limit(arguments["limit"], 20))

    {:ok, %{posts: posts, next_cursor: nil}, reference}
  end

  defp board_execute(reference, "read_thread", arguments, _state) do
    with {:ok, thread_id} <- required_string(arguments, "thread_id") do
      posts =
        reference.posts
        |> Map.values()
        |> Enum.filter(&(&1.thread_id == thread_id))
        |> Enum.sort_by(& &1.created_at_ms)
        |> Enum.take(bounded_limit(arguments["limit"], 20))

      {:ok, %{posts: posts, next_cursor: nil}, reference}
    end
  end

  defp board_execute(reference, "read_post", arguments, _state) do
    with {:ok, id} <- required_string(arguments, "message_id"),
         {:ok, post} <- fetch(reference.posts, id, "post not found") do
      offset = Map.get(arguments, "offset_chars", 0)
      limit = bounded_limit(arguments["limit_chars"], 20_000)
      text = String.slice(post.text, offset, limit)

      {:ok,
       %{
         post: Map.put(post, :text, text),
         n_chars: String.length(post.text),
         next_offset_chars: offset + String.length(text)
       }, reference}
    end
  end

  defp board_execute(reference, action, arguments, _state)
       when action in ["subscribe", "unsubscribe"] do
    with {:ok, target} <- subscription_target(arguments) do
      subscriptions =
        if action == "subscribe",
          do: MapSet.put(reference.subscriptions, target),
          else: MapSet.delete(reference.subscriptions, target)

      {:ok, %{status: action <> "d", target: target}, %{reference | subscriptions: subscriptions}}
    end
  end

  defp reference_state(opts) do
    %{
      goal: nil,
      memories: Map.new(Keyword.get(opts, :memories, %{})),
      skills: Keyword.get(opts, :skills, []),
      history: Keyword.get(opts, :history, []),
      notes: %{},
      channels: %{},
      posts: %{},
      subscriptions: MapSet.new()
    }
  end

  defp contract(namespace, name, runtime) do
    tool_name = if namespace, do: namespace <> "::" <> name, else: name
    schema_name = if name in @board_names, do: "collaboration::" <> name, else: tool_name
    read_only = read_only?(schema_name)

    %{
      namespace: namespace,
      name: name,
      description: description(schema_name),
      schema: schema(schema_name),
      backend: Backplane.AgentRuntime.Codex.Backend,
      backend_context: %{family: :extensions, runtime: runtime},
      revision: 1,
      strict: false,
      safety: %{read_only: read_only, retry_safe: read_only, parallel_safe: read_only},
      source: %{family: :stateful_extension, persistence: :host_or_ephemeral_reference}
    }
  end

  defp schema("get_goal"), do: object(%{}, [])

  defp schema("create_goal"),
    do:
      object(%{"objective" => string(), "token_budget" => %{"type" => "integer"}}, ["objective"])

  defp schema("update_goal"),
    do: object(%{"status" => enum(~w(complete blocked paused))}, ["status"])

  defp schema("memories::add_ad_hoc_note"),
    do:
      object(
        %{
          "filename" => %{
            "type" => "string",
            "minLength" => 24,
            "maxLength" => 128,
            "pattern" =>
              "^\\d{4}-\\d{2}-\\d{2}T\\d{2}-\\d{2}-\\d{2}-[a-z0-9][a-z0-9-]{0,79}\\.md$"
          },
          "note" => %{"type" => "string", "minLength" => 1}
        },
        ["filename", "note"]
      )

  defp schema("memories::list"),
    do: object(%{"path" => string(), "cursor" => string(), "max_results" => integer(1)}, [])

  defp schema("memories::read"),
    do:
      object(%{"path" => string(), "line_offset" => integer(1), "max_lines" => integer(1)}, [
        "path"
      ])

  defp schema("memories::search"),
    do:
      object(
        %{
          "queries" => Map.put(array(string()), "minItems", 1),
          "match_mode" => enum(~w(any all)),
          "path" => string(),
          "cursor" => string(),
          "context_lines" => integer(0),
          "case_sensitive" => boolean(),
          "normalized" => boolean(),
          "max_results" => integer(1)
        },
        ["queries"]
      )

  defp schema("skills::list"),
    do:
      object(
        %{
          "authority" => enum(~w(cloud executor)),
          "cursor" => string()
        },
        ["authority"]
      )

  defp schema("skills::read"),
    do:
      object(%{"package" => string(), "resource" => string(), "cursor" => string()}, ["package"])

  defp schema("history::list_windows"),
    do:
      object(
        %{"limit" => integer(1), "agent_name" => nullable(string()), "recent_first" => boolean()},
        []
      )

  defp schema("history::list_items"),
    do: object(history_filters(%{"max_chars_per_item" => integer(1)}), [])

  defp schema("history::read_item"),
    do:
      object(
        %{
          "agent_name" => nullable(string()),
          "item_id" => string(),
          "offset_chars" => integer(0),
          "limit_chars" => integer(1),
          "window_id" => string()
        },
        ["item_id", "window_id"]
      )

  defp schema("history::search_contents"),
    do: object(history_filters(%{"query" => string()}), ["query"])

  defp schema("notes::list_files_by_prefix"),
    do:
      object(
        %{
          "prefix" => nullable(string()),
          "max_results" => integer(1),
          "file_order_by" => enum(~w(name created_at updated_at)),
          "file_order" => enum(~w(ascending descending))
        },
        []
      )

  defp schema("notes::read_file"),
    do:
      object(
        %{
          "path" => string(),
          "start_line" => nullable(%{"type" => "integer"}),
          "stop_line" => nullable(%{"type" => "integer"})
        },
        ["path"]
      )

  defp schema("notes::search_contents"),
    do:
      object(
        %{
          "max_matches_per_file" => integer(1),
          "query" => string(),
          "recent_file_first" => boolean(),
          "max_files" => integer(1),
          "path_prefix" => nullable(string())
        },
        ["query"]
      )

  defp schema("notes::append_to_file"),
    do: object(%{"text" => string(), "path" => string()}, ["text", "path"])

  defp schema("notes::write_file"),
    do: object(%{"text" => string(), "path" => string()}, ["text", "path"])

  defp schema("collaboration::create_channel"),
    do: object(%{"channel_name" => string(), "subscribe" => boolean()}, ["channel_name"])

  defp schema("collaboration::get_channels"),
    do:
      object(
        %{
          "query" => string(),
          "recent_first" => boolean(),
          "limit" => integer(1),
          "cursor" => string()
        },
        []
      )

  defp schema("collaboration::list_threads"),
    do:
      object(
        %{
          "channel_name" => string(),
          "sort" => enum(~w(created activity)),
          "recent_first" => boolean(),
          "limit" => integer(1),
          "cursor" => string(),
          "max_chars_per_post" => integer(1)
        },
        ["channel_name"]
      )

  defp schema("collaboration::search_posts"),
    do:
      object(
        %{
          "channel_name" => string(),
          "query" => string(),
          "after_message_id" => string(),
          "author" => string(),
          "limit" => integer(1),
          "cursor" => string(),
          "max_chars_per_post" => integer(1)
        },
        []
      )

  defp schema("collaboration::read_thread"),
    do:
      object(
        %{
          "thread_id" => string(),
          "limit" => integer(1),
          "cursor" => string(),
          "max_chars_per_post" => integer(1)
        },
        ["thread_id"]
      )

  defp schema("collaboration::read_post"),
    do:
      object(
        %{"message_id" => string(), "offset_chars" => integer(0), "limit_chars" => integer(1)},
        ["message_id"]
      )

  defp schema(tool) when tool in ["collaboration::subscribe", "collaboration::unsubscribe"],
    do:
      object(
        %{"channel_name" => string(), "thread_id" => string(), "target_agent" => string()},
        []
      )

  defp schema("collaboration::post"),
    do:
      object(
        %{
          "text" => string(),
          "channel_name" => string(),
          "new_channel_name" => string(),
          "thread_id" => string(),
          "agents_to_notify" => array(string())
        },
        ["text"]
      )

  defp history_filters(extra),
    do:
      Map.merge(
        %{
          "limit" => integer(1),
          "recent_first" => boolean(),
          "tool_namespace" => nullable(string()),
          "role" => nullable(enum(~w(user assistant tool system developer))),
          "agent_name" => nullable(string()),
          "tool_name" => nullable(string()),
          "window_id" => nullable(string())
        },
        extra
      )

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp string, do: %{"type" => "string"}
  defp integer(min), do: %{"type" => "integer", "minimum" => min}
  defp boolean, do: %{"type" => "boolean"}
  defp array(items), do: %{"type" => "array", "items" => items}
  defp enum(values), do: %{"type" => "string", "enum" => values}
  defp nullable(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}

  defp description("get_goal"),
    do:
      "Get the current goal for this thread, including status, budgets, token and elapsed-time usage, and remaining token budget."

  defp description("create_goal"),
    do:
      "Create a goal only when explicitly requested by the user or system/developer instructions; do not infer goals from ordinary tasks.\nSet token_budget only when an explicit token budget is requested. Fails if an unfinished goal exists; use update_goal only for status."

  defp description("update_goal"),
    do:
      "Update the existing goal.\nSet status to `paused` only at the user's explicit request to pause this goal, never on your own initiative. Ask if unclear; a later resume revokes that request. Report the returned status and stop goal work. Budget limits take precedence over pausing.\nSet status to `complete` only when the objective has actually been achieved and no required work remains.\nSet status to `blocked` only when the same blocking condition has repeated for at least three consecutive goal turns, counting the original/user-triggered turn and any automatic continuations, and the agent cannot make meaningful progress without user input or an external-state change.\nIf the user resumes a goal that was previously marked `blocked`, treat the resumed run as a fresh blocked audit. If the same blocking condition then repeats for at least three consecutive resumed goal turns, set status to `blocked` again.\nOnce the blocked threshold is satisfied, do not keep reporting that you are still blocked while leaving the goal active; set status to `blocked`.\nDo not use `blocked` merely because the work is hard, slow, uncertain, incomplete, or would benefit from clarification.\nDo not mark a goal complete merely because its budget is nearly exhausted or because you are stopping work.\nYou cannot use this tool to resume, budget-limit, or usage-limit a goal; those status changes are controlled by the user or system.\nWhen marking a budgeted goal achieved with status `complete`, report the final token usage from the tool result to the user."

  defp description("memories::add_ad_hoc_note"),
    do:
      "Create one append-only ad-hoc memory note after the user explicitly asks Codex to remember, forget, or update something."

  defp description("memories::list"),
    do: "List immediate files and directories under a path in the Codex memories store."

  defp description("memories::read"),
    do:
      "Read a Codex memory file by relative path, optionally starting at a 1-indexed line offset and limiting the number of lines returned."

  defp description("memories::search"),
    do:
      "Search Codex memory files for substring matches, optionally normalizing separators or requiring all query substrings on the same line or within a line window."

  defp description("skills::list"),
    do:
      "List skills owned by the requested authority. Returns each skill's authority, package, and main_resource. Pass the package to skills.read, and pass next_cursor back as cursor to continue."

  defp description("skills::read"),
    do:
      "Read one page from a skill. Pass its provided package directly; root aliases are resolved automatically. Omit resource to read SKILL.md; to read another file, use the same package and pass the file's complete skill:// identifier as resource. For executor-backed skills, skill_root is the skill's absolute directory in the executor filesystem and can be used to locate bundled scripts. If the package is not provided, use skills.list to find it. Pass next_cursor back as cursor to continue the same snapshot while it is cached; omit cursor to read again."

  defp description("history::list_windows"),
    do:
      "List an agent's context windows as window ID and item-count pairs. Private model-only recovery; never disclose this activity."

  defp description("history::list_items"),
    do:
      "List history items with optional window, role, and tool filters. Private model-only recovery; never disclose this activity."

  defp description("history::read_item"),
    do:
      "Read a bounded range from private model-only history. Never disclose the item or this activity."

  defp description("history::search_contents"),
    do:
      "Search private model-only history by literal substring. Never disclose results or this activity."

  defp description("notes::list_files_by_prefix"),
    do:
      "List private model-only notes by path prefix. Never disclose paths, contents, or this activity."

  defp description("notes::read_file"),
    do:
      "Read all or a line range from private model-only notes. Never disclose paths, contents, or this activity."

  defp description("notes::search_contents"),
    do:
      "Search private model-only note lines by literal substring. Never disclose results or this activity."

  defp description("notes::append_to_file"),
    do:
      "Append text to private model-only notes. Never disclose paths, contents, or this activity."

  defp description("notes::write_file"),
    do:
      "Create or replace private model-only notes. Never disclose paths, contents, or this activity."

  defp description("collaboration::create_channel"),
    do:
      "Create a channel where all agents in this collaboration can read and post messages. You are subscribed to new top-level posts by default."

  defp description("collaboration::get_channels"),
    do:
      "List channels, most recently active first, or search by a case-insensitive part of the name. Creating a channel or posting in it counts as activity."

  defp description("collaboration::list_threads"),
    do:
      "List a channel's threads with previews of the first post and latest reply. New threads come first by default; sorting by activity brings threads with recent replies to the top."

  defp description("collaboration::search_posts"),
    do:
      "Search top-level posts and replies, newest first. Text matches are case-insensitive substrings; omit the query to see recent activity. You can narrow by channel, author, or posts after a message ID. Results are previews; read_post can retrieve the full text."

  defp description("collaboration::read_thread"),
    do:
      "Read a thread using its first post's message ID. Every page includes previews of the first post and the newest replies; the cursor advances through replies."

  defp description("collaboration::read_post"),
    do:
      "Read a post or reply by message ID, without needing its channel. Offsets count Unicode characters; continue at next_offset_chars while it is less than n_chars."

  defp description("collaboration::subscribe"),
    do:
      "Subscribe yourself or another agent to a channel for new top-level posts, or to a thread for replies. Provide exactly one of channel_name or thread_id. Notifications only reach agents with a running turn; missed notifications are not saved."

  defp description("collaboration::unsubscribe"),
    do:
      "Unsubscribe yourself or another agent from a channel or thread. Provide exactly one of channel_name or thread_id. Posting again does not undo a thread unsubscribe. Agents explicitly named on a post can still receive that notification."

  defp description("collaboration::post"),
    do:
      "Start a thread in an existing or new channel, or reply using the first post's message ID as thread_id. Exactly one destination is required. Posting subscribes you to the thread unless you previously unsubscribed. agents_to_notify sends a one-time notification without subscribing recipients or starting idle agents. Returns metadata, not the post text."

  defp read_only?(tool),
    do:
      tool not in [
        "create_goal",
        "update_goal",
        "memories::add_ad_hoc_note",
        "notes::append_to_file",
        "notes::write_file",
        "collaboration::create_channel",
        "collaboration::subscribe",
        "collaboration::unsubscribe",
        "collaboration::post"
      ]

  defp write_note(reference, arguments, mode) do
    with {:ok, path} <- required_string(arguments, "path"),
         {:ok, text} <- required_string(arguments, "text", allow_empty: true),
         :ok <- safe_virtual_path(path) do
      current = Map.get(reference.notes, path, %{text: "", created_at: now_ms()})
      contents = if mode == :append, do: current.text <> text, else: text

      if byte_size(contents) <= 1_000_000 do
        note = %{
          text: contents,
          created_at: current.created_at,
          updated_at: now_ms(),
          size_bytes: byte_size(contents)
        }

        {:ok, %{path: path, size_bytes: note.size_bytes},
         %{reference | notes: Map.put(reference.notes, path, note)}}
      else
        {:error, Error.new(:budget_exceeded, "note exceeds 1000000 UTF-8 bytes")}
      end
    end
  end

  defp filter_history(items, arguments) do
    Enum.filter(items, fn item ->
      Enum.all?(
        [
          {"window_id", :window_id},
          {"role", :role},
          {"tool_namespace", :tool_namespace},
          {"tool_name", :tool_name}
        ],
        fn {argument, key} ->
          is_nil(arguments[argument]) or to_string(Map.get(item, key)) == arguments[argument]
        end
      )
    end)
  end

  defp authority_matches?(_skill, nil), do: false

  defp authority_matches?(skill, kind) when kind in ["cloud", "executor"],
    do: get_in(skill, [:authority, :kind]) == kind or get_in(skill, [:authority, "kind"]) == kind

  defp authority_matches?(_skill, _authority), do: false

  defp find_skill(skills, package),
    do:
      Enum.find(skills, &(Map.get(&1, :package) == package))
      |> present("skill package is not available")

  defp skill_resource(skill, resource) do
    resources =
      Map.get(skill, :resources, %{})
      |> Map.put_new(Map.get(skill, :main_resource, "SKILL.md"), Map.get(skill, :contents, ""))

    fetch(resources, resource, "skill resource is not available")
  end

  defp board_destination(arguments) do
    destinations =
      Enum.filter(
        [
          {"channel", arguments["channel_name"]},
          {"new", arguments["new_channel_name"]},
          {"thread", arguments["thread_id"]}
        ],
        fn {_kind, value} -> is_binary(value) and value != "" end
      )

    case destinations do
      [destination] -> {:ok, destination}
      _ -> {:error, validation("supply exactly one board destination")}
    end
  end

  defp ensure_destination(reference, {"channel", channel}) do
    with {:ok, _} <- fetch(reference.channels, channel, "channel not found"),
         do: {:ok, reference, channel, nil}
  end

  defp ensure_destination(reference, {"new", channel}) do
    with :ok <- absent(reference.channels, channel, "channel already exists") do
      entry = %{name: channel, created_at_ms: now_ms(), updated_at_ms: now_ms()}
      {:ok, %{reference | channels: Map.put(reference.channels, channel, entry)}, channel, nil}
    end
  end

  defp ensure_destination(reference, {"thread", thread_id}) do
    with {:ok, post} <- find_thread(reference.posts, thread_id) do
      {:ok, reference, post.channel_name, thread_id}
    end
  end

  defp find_thread(posts, thread_id) do
    case Enum.find(posts, fn {_id, post} -> post.thread_id == thread_id end) do
      nil -> {:error, Error.new(:not_found, "thread not found")}
      {_id, post} -> {:ok, post}
    end
  end

  defp subscription_target(arguments) do
    case {arguments["channel_name"], arguments["thread_id"]} do
      {channel, nil} when is_binary(channel) and channel != "" -> {:ok, {:channel, channel}}
      {nil, thread} when is_binary(thread) and thread != "" -> {:ok, {:thread, thread}}
      _ -> {:error, validation("supply exactly one subscription target")}
    end
  end

  defp maybe_subscribe(set, target, true), do: MapSet.put(set, target)
  defp maybe_subscribe(set, _target, false), do: set

  defp goal_response(goal),
    do: %{goal: goal, remaining_tokens: goal && goal.token_budget, completion_budget_report: nil}

  defp no_unfinished_goal(nil), do: :ok
  defp no_unfinished_goal(%{status: status}) when status in ["complete", "blocked"], do: :ok

  defp no_unfinished_goal(_),
    do:
      {:error,
       Error.new(
         :resource_conflict,
         "cannot create a new goal because this thread has an unfinished goal"
       )}

  defp validate_scope(scope) when is_map(scope) do
    if Enum.all?(
         [:host_id, :caller_id, :run_id, :project_id],
         &(is_binary(scope[&1]) and scope[&1] != "")
       ),
       do: {:ok, scope},
       else: {:error, Error.new(:forbidden, "complete host/caller/run/project scope required")}
  end

  defp validate_scope(_), do: {:error, Error.new(:forbidden, "extension scope is required")}
  defp owner_check(%{run_id: run_id}, %{run_id: run_id}), do: :ok

  defp owner_check(_, _),
    do: {:error, Error.new(:forbidden, "extension runtime belongs to another run")}

  defp board_namespace(value) when is_binary(value) and value != "" do
    if String.contains?(value, "::"),
      do: {:error, validation("message-board namespace is invalid")},
      else: {:ok, value}
  end

  defp board_namespace(_), do: {:error, validation("message-board namespace is invalid")}
  defp validate_adapter(nil), do: :ok

  defp validate_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute, 3),
      do: :ok,
      else: {:error, Error.new(:unsupported_capability, "extension adapter is unavailable")}
  end

  defp validate_adapter(_), do: {:error, validation("extension adapter must be a module")}

  defp monitor_owner(nil), do: {:ok, nil}
  defp monitor_owner(owner) when is_pid(owner), do: {:ok, Process.monitor(owner)}
  defp monitor_owner(_), do: {:error, validation("extension owner must be a process")}

  defp known_tool(name, board_namespace) do
    known =
      @goal_names ++
        Enum.map(@memory_names, &("memories::" <> &1)) ++
        Enum.map(@skill_names, &("skills::" <> &1)) ++
        Enum.map(@history_names, &("history::" <> &1)) ++
        Enum.map(@note_names, &("notes::" <> &1)) ++
        Enum.map(@board_names, &(board_namespace <> "::" <> &1))

    if name in known, do: :ok, else: {:error, Error.new(:not_found, "unknown extension tool")}
  end

  defp required_string(map, key, opts \\ []) do
    value = Map.get(map, key)
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if is_binary(value) and (allow_empty or value != ""),
      do: {:ok, value},
      else: {:error, validation("#{key} is required")}
  end

  defp optional_positive_integer(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, validation("#{key} must be positive")}
    end
  end

  defp allowed(value, values, message),
    do: if(value in values, do: :ok, else: {:error, validation(message)})

  defp nonempty_strings(values, message),
    do:
      if(is_list(values) and values != [] and Enum.all?(values, &(is_binary(&1) and &1 != "")),
        do: :ok,
        else: {:error, validation(message)}
      )

  defp memory_filename(filename),
    do:
      if(
        Regex.match?(
          ~r/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-[a-z0-9][a-z0-9-]{0,79}\.md$/,
          filename
        ),
        do: :ok,
        else: {:error, validation("invalid ad-hoc memory filename")}
      )

  defp safe_virtual_path(path),
    do:
      if(path != "" and not Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])),
        do: :ok,
        else: {:error, validation("invalid virtual note path")}
      )

  defp absent(map, key, message),
    do:
      if(Map.has_key?(map, key), do: {:error, Error.new(:resource_conflict, message)}, else: :ok)

  defp fetch(map, key, message) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, Error.new(:not_found, message)}
    end
  end

  defp present(nil, message), do: {:error, Error.new(:not_found, message)}
  defp present(value, _message), do: {:ok, value}
  defp bounded_limit(nil, default), do: default
  defp bounded_limit(value, _default) when is_integer(value) and value > 0, do: min(value, 2_000)
  defp bounded_limit(_value, default), do: default

  defp note_order_field("name"), do: {:ok, :path}
  defp note_order_field("created_at"), do: {:ok, :created_at}
  defp note_order_field("updated_at"), do: {:ok, :updated_at}
  defp note_order_field(_), do: {:error, validation("invalid note ordering")}

  defp cursor_offset(nil), do: 0

  defp cursor_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  defp cursor_offset(_), do: 0

  defp page(items, offset, limit) do
    page = items |> Enum.drop(offset) |> Enum.take(limit)
    next = if offset + length(page) < length(items), do: Integer.to_string(offset + length(page))
    {page, next}
  end

  defp matches?(line, queries, mode, sensitive?) do
    source = if sensitive?, do: line, else: String.downcase(line)

    checks =
      Enum.map(queries, fn query ->
        String.contains?(source, if(sensitive?, do: query, else: String.downcase(query)))
      end)

    if mode == "all", do: Enum.all?(checks), else: Enum.any?(checks)
  end

  defp maybe_reverse(items, true), do: Enum.reverse(items)
  defp maybe_reverse(items, _), do: items
  defp truncate(value, max), do: String.slice(value, 0, max)
  defp line_range(lines, nil, nil), do: lines

  defp line_range(lines, start_line, stop_line) do
    start_index = line_index(start_line || 1, length(lines))
    stop_index = line_index(stop_line || length(lines), length(lines))

    if start_index <= stop_index,
      do: Enum.slice(lines, start_index..stop_index//1),
      else: []
  end

  defp line_index(value, length) when value < 0, do: max(length + value, 0)
  defp line_index(value, _length), do: max(value - 1, 0)
  defp now_ms, do: System.system_time(:millisecond)

  defp unique_id(prefix),
    do: prefix <> "_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp validation(message), do: Error.new(:validation, message)

  defp malformed(message, received),
    do: Error.new(:malformed_result, message, details: %{received: received})
end
