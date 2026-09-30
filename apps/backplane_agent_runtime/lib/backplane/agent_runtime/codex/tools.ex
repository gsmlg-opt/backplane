defmodule Backplane.AgentRuntime.Codex.Tools do
  @moduledoc "Pinned local Codex tool contracts and executable host adapters."

  alias Backplane.AgentRuntime.{Command, Error, Plan}
  alias Backplane.AgentRuntime.Codex.{ApplyPatch, Contract, PathGuard, ResourceRegistry}

  @image_limit 10 * 1024 * 1024
  @max_sleep_ms 12 * 60 * 60 * 1_000

  @apply_patch_grammar """
  start: begin_patch hunk+ end_patch
  begin_patch: "*** Begin Patch" LF
  end_patch: "*** End Patch" LF?

  hunk: add_hunk | delete_hunk | update_hunk
  add_hunk: "*** Add File: " filename LF add_line+
  delete_hunk: "*** Delete File: " filename LF
  update_hunk: "*** Update File: " filename LF change_move? change?

  filename: /(.+)/
  add_line: "+" /(.*)/ LF -> line

  change_move: "*** Move to: " filename LF
  change: (change_context | change_line)+ eof_line?
  change_context: ("@@" | "@@ " /(.+)/) LF
  change_line: ("+" | "-" | " ") /(.*)/ LF
  eof_line: "*** End of File" LF

  %import common.LF
  """

  @spec definitions() :: [map()]
  def definitions do
    Enum.map(contract_attrs(%{}), fn attrs ->
      {:ok, contract} = Contract.new(attrs)
      Contract.provider_definition(contract)
    end)
  end

  @spec contracts(map()) :: [map()]
  def contracts(context) when is_map(context) do
    contract_attrs(context)
    |> Enum.filter(&configured?(&1, context))
  end

  @spec call(map(), String.t(), map() | String.t()) :: {:ok, map()} | {:error, Error.t()}
  def call(context, "exec_command", args) when is_map(args), do: exec_command(context, args)
  def call(context, "write_stdin", args) when is_map(args), do: write_stdin(context, args)
  def call(context, "apply_patch", patch) when is_binary(patch), do: apply_patch(context, patch)

  def call(context, "apply_patch", args) when is_map(args),
    do: apply_patch(context, Map.get(args, "patch") || Map.get(args, :patch, ""))

  def call(context, "update_plan", args) when is_map(args), do: update_plan(context, args)
  def call(context, "view_image", args) when is_map(args), do: view_image(context, args)
  def call(_context, "clock::curr_time", args) when is_map(args), do: current_time()
  def call(_context, "clock::sleep", args) when is_map(args), do: sleep(args)

  # Explicit Backplane compatibility aliases retained for existing embedders.
  def call(context, "clock", args), do: call(context, "clock::curr_time", args)

  def call(context, "wait", args) when is_map(args) do
    call(context, "clock::sleep", %{
      "duration_ms" => Map.get(args, "milliseconds", Map.get(args, "timeout_ms", 0))
    })
  end

  def call(_context, _name, args) when not is_map(args) and not is_binary(args),
    do: {:error, Error.new(:validation, "Codex tool arguments are malformed")}

  def call(_context, name, _args),
    do: {:error, Error.new(:not_found, "unknown Codex tool", details: %{tool: name})}

  defp exec_command(%{command: command, caller: caller} = context, args) do
    with :ok <- reject_unsupported_exec_options(args),
         {:ok, invocation} <- command_args(args, caller, context),
         {:ok, session_id} <- reserve_command_session(context, command, invocation) do
      invocation = Map.put(invocation, :session_id, session_id)

      case Command.start(command, invocation,
             deadline_limit: command.deadline_limit,
             output_limit: command.output_limit
           ) do
        {:ok, job} ->
          with :ok <- bind_command_session(context, session_id, invocation, job),
               {:ok, result} <- poll(command, invocation, job, 0, yield_time(args, false)),
               :ok <- settle_command_session(context, session_id, invocation, job, result) do
            {:ok, budget_response(format_command_result(result, session_id), args)}
          else
            {:error, %Error{} = error} ->
              case release_command_session(context, session_id, invocation) do
                {:ok, _} -> {:error, error}
                {:error, %Error{} = cleanup_error} -> {:error, cleanup_error}
              end
          end

        {:error, %Error{} = error} ->
          case release_command_session(context, session_id, invocation) do
            {:ok, _} -> {:error, error}
            {:error, %Error{} = cleanup_error} -> {:error, cleanup_error}
          end
      end
    end
  end

  defp exec_command(_context, _args),
    do: {:error, Error.new(:unsupported_capability, "command and caller are not configured")}

  defp write_stdin(
         %{command: command, caller: caller, session_registry: registry} = context,
         %{"session_id" => session_id} = args
       )
       when is_pid(registry) and is_integer(session_id) do
    caller_run_id = Map.get(caller, :run_id)
    incarnation = Map.get(context, :incarnation, 1)
    invocation = %{owner_run_id: caller_run_id, incarnation: incarnation}

    with {:ok, session} <-
           ResourceRegistry.fetch_session(registry, session_id, caller_run_id, incarnation),
         :ok <- write_chars(command, invocation, session.job, Map.get(args, "chars", "")),
         {:ok, result} <-
           poll(
             command,
             invocation,
             session.job,
             session.cursor,
             yield_time(args, Map.get(args, "chars", "") != "")
           ),
         :ok <- settle_session(registry, session_id, caller_run_id, incarnation, session, result) do
      {:ok, budget_response(format_command_result(result, session_id), args)}
    end
  end

  # Compatibility path for callers that still hold the opaque Backplane job.
  defp write_stdin(%{command: command, caller: caller}, args) do
    job = Map.get(args, "job") || Map.get(args, :job)
    invocation = %{owner_run_id: Map.get(caller, :run_id)}

    with true <- is_map(job) or {:error, Error.new(:validation, "session_id is required")},
         {:ok, result} <- Command.read(command, invocation, job, cursor: 0) do
      {:ok, budget_response(format_command_result(result, nil), args)}
    end
  end

  defp write_stdin(_context, _args),
    do: {:error, Error.new(:unsupported_capability, "command and caller are not configured")}

  defp apply_patch(%{workspace: root}, patch) when is_binary(root) and is_binary(patch),
    do: ApplyPatch.apply(root, patch)

  defp apply_patch(_context, _patch),
    do: {:error, Error.new(:unsupported_capability, "workspace is not configured")}

  defp update_plan(%{plan: server}, args) when is_pid(server) do
    content = %{
      "explanation" => Map.get(args, "explanation"),
      "plan" => Map.get(args, "plan")
    }

    with true <- is_list(content["plan"]) or {:error, Error.new(:validation, "plan is required")},
         {:ok, %{revision: revision}} <- Plan.read(server),
         {:ok, result} <- Plan.update(server, revision, content) do
      {:ok, %{revision: result.revision, status: :updated}}
    end
  end

  defp update_plan(_context, _args),
    do: {:error, Error.new(:unsupported_capability, "plan is not configured")}

  defp view_image(%{workspace: root}, args) when is_binary(root) do
    path = Map.get(args, "path") || Map.get(args, :path)
    detail = Map.get(args, "detail", "high")

    with {:ok, full} <- confined(root, path),
         {:ok, canonical_root} <- confined(root, root),
         {:ok, stat} <- File.stat(full),
         true <-
           stat.size <= @image_limit or
             {:error, Error.new(:resource_conflict, "image exceeds size limit")},
         {:ok, mime} <- image_mime(full),
         {:ok, data} <- File.read(full) do
      {:ok,
       %{
         path: Path.relative_to(full, canonical_root),
         detail: detail,
         mime_type: mime,
         data: data,
         bytes: byte_size(data),
         image_url: "data:#{mime};base64,#{Base.encode64(data)}"
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:resource_conflict, "image read failed", cause: reason)}
    end
  end

  defp view_image(_context, _args),
    do: {:error, Error.new(:unsupported_capability, "workspace is not configured")}

  defp current_time do
    {:ok, %{current_time: Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")}}
  end

  defp sleep(args) do
    duration = Map.get(args, "duration_ms", Map.get(args, :duration_ms))

    if is_integer(duration) and duration in 1..@max_sleep_ms do
      started = System.monotonic_time(:microsecond)
      Process.sleep(duration)

      {:ok, %{wall_time_seconds: (System.monotonic_time(:microsecond) - started) / 1_000_000}}
    else
      {:error, Error.new(:validation, "duration_ms must be between 1 and #{@max_sleep_ms}")}
    end
  end

  defp command_args(args, caller, context) do
    cmd = Map.get(args, "cmd")
    workspace = Map.get(args, "workdir", Map.get(context, :workspace))
    shell = Map.get(args, "shell") || System.get_env("SHELL") || "/bin/sh"
    shell_flag = if Map.get(args, "login", true), do: "-lc", else: "-c"

    with true <- is_binary(cmd) and cmd != "" and is_binary(workspace),
         {:ok, workspace} <- authorize_workspace(context, workspace) do
      {:ok,
       %{
         executable: shell,
         arguments: [shell_flag, cmd],
         workspace: workspace,
         environment: %{},
         owner_run_id: Map.get(caller, :run_id),
         incarnation: Map.get(context, :incarnation, 1),
         owner_pid: Map.get(context, :owner_pid)
       }}
    else
      false -> {:error, Error.new(:validation, "cmd is required")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp reject_unsupported_exec_options(args) do
    cond do
      Map.get(args, "tty", false) ->
        {:error, Error.new(:unsupported_capability, "PTY execution is unavailable")}

      Map.get(args, "sandbox_permissions", "use_default") != "use_default" ->
        {:error, Error.new(:forbidden, "sandbox override was not granted by the host")}

      true ->
        :ok
    end
  end

  # The response budget is an estimate in bytes, independent of the host-owned
  # backend hard cap. The backend cursor consumes the entire observed batch;
  # omitted bytes are deliberately discarded, never replayed on the next poll.
  defp budget_response(result, args) do
    tokens = Map.get(args, "max_output_tokens", 10_000)
    limit = if is_number(tokens) and tokens > 0, do: trunc(tokens * 4), else: 40_000
    output = result.output
    prefix = binary_part(output, 0, min(byte_size(output), limit))
    prefix = valid_utf8_prefix(prefix)
    omitted = byte_size(output) - byte_size(prefix)

    Map.merge(result, %{
      output: prefix,
      output_truncated: omitted > 0,
      omitted_output_bytes: omitted,
      output_budget_unit: :estimated_token_bytes
    })
  end

  defp valid_utf8_prefix(bytes) do
    case :unicode.characters_to_binary(bytes) do
      binary when is_binary(binary) -> binary
      {_reason, prefix, _rest} -> prefix
    end
  end

  defp reserve_command_session(%{session_registry: registry} = context, command, invocation)
       when is_pid(registry) do
    owner = invocation.owner_run_id
    timeout = Map.get(context, :cleanup_timeout, 4_000)
    owner_pid = Map.get(context, :owner_pid)

    cleanup = fn %{session_id: session_id} ->
      Command.cancel_confirmed(
        command,
        %{owner_run_id: owner, session_id: session_id},
        timeout
      )
    end

    resource_opts =
      [cleanup: cleanup, incarnation: invocation.incarnation] |> maybe_put_owner(owner_pid)

    ResourceRegistry.register_session(registry, owner, %{job: nil, cursor: 0}, resource_opts)
  end

  defp reserve_command_session(_context, _command, _invocation), do: {:ok, nil}

  defp bind_command_session(%{session_registry: registry}, id, invocation, job)
       when is_pid(registry) and is_integer(id) do
    ResourceRegistry.update_session(
      registry,
      id,
      invocation.owner_run_id,
      %{job: job, cursor: 0},
      invocation.incarnation
    )
  end

  defp bind_command_session(_context, _id, _invocation, _job), do: :ok

  defp settle_command_session(%{session_registry: registry}, id, invocation, job, result)
       when is_pid(registry) and is_integer(id) do
    session = %{job: job, cursor: result.cursor}
    settle_session(registry, id, invocation.owner_run_id, invocation.incarnation, session, result)
  end

  defp settle_command_session(_context, _id, _invocation, _job, _result), do: :ok

  defp release_command_session(%{session_registry: registry}, id, invocation)
       when is_pid(registry) and is_integer(id) do
    ResourceRegistry.release_session(
      registry,
      id,
      invocation.owner_run_id,
      invocation.incarnation
    )
  end

  defp release_command_session(_context, _id, _invocation), do: {:ok, :not_tracked}

  defp maybe_put_owner(opts, owner_pid) when is_pid(owner_pid),
    do: Keyword.put(opts, :owner_pid, owner_pid)

  defp maybe_put_owner(opts, _owner_pid), do: opts

  defp poll(command, invocation, job, cursor, wait_ms) do
    started = System.monotonic_time(:millisecond)
    poll_until(command, invocation, job, cursor, started, wait_ms)
  end

  defp poll_until(command, invocation, job, cursor, started, wait_ms) do
    with {:ok, result} <- Command.read(command, invocation, job, cursor: cursor) do
      elapsed = System.monotonic_time(:millisecond) - started

      if (result.status == :running or Map.get(result, :cleanup_status) == :pending) and
           elapsed < wait_ms do
        Process.sleep(min(10, wait_ms - elapsed))
        poll_until(command, invocation, job, cursor, started, wait_ms)
      else
        {:ok, Map.put(result, :wall_time_seconds, elapsed / 1_000)}
      end
    end
  end

  defp write_chars(_command, _invocation, _job, ""), do: :ok

  defp write_chars(command, invocation, job, chars),
    do: Command.write(command, invocation, job, chars)

  defp settle_session(
         registry,
         session_id,
         owner,
         incarnation,
         session,
         %{status: :running} = result
       ) do
    ResourceRegistry.update_session(
      registry,
      session_id,
      owner,
      %{session | cursor: result.cursor},
      incarnation
    )
  end

  defp settle_session(
         registry,
         session_id,
         owner,
         incarnation,
         session,
         %{cleanup_status: status} = result
       )
       when status in [:pending, :uncertain] do
    with :ok <-
           ResourceRegistry.update_session(
             registry,
             session_id,
             owner,
             %{session | cursor: result.cursor},
             incarnation
           ) do
      if status == :uncertain,
        do: {:error, Error.new(:unknown_outcome, "command cleanup is unconfirmed")},
        else: :ok
    end
  end

  defp settle_session(registry, session_id, owner, incarnation, _session, _result),
    do: ResourceRegistry.forget_session(registry, session_id, owner, incarnation)

  defp format_command_result(result, session_id) do
    %{
      output: output_text(result.output),
      status: result.status,
      termination_status: Map.get(result, :termination_status),
      cleanup_status: Map.get(result, :cleanup_status),
      cleanup_error: Map.get(result, :cleanup_error),
      output_limit_exceeded?: Map.get(result, :output_limit_exceeded?),
      wall_time_seconds: Map.get(result, :wall_time_seconds, 0.0),
      exit_code: Map.get(result, :exit_status),
      session_id:
        if(
          result.status == :running or Map.get(result, :cleanup_status) in [:pending, :uncertain],
          do: session_id
        )
    }
    |> compact()
  end

  defp yield_time(args, writing?) do
    default = if writing?, do: 250, else: 5_000
    maximum = if writing?, do: 30_000, else: 300_000

    case Map.get(args, "yield_time_ms", default) do
      value when is_integer(value) -> value |> max(0) |> min(maximum)
      _ -> default
    end
  end

  defp authorize_workspace(%{workspace: root}, workspace) when is_binary(root),
    do: PathGuard.authorize(root, workspace)

  defp authorize_workspace(_context, workspace), do: {:ok, workspace}
  defp confined(root, path) when is_binary(path), do: PathGuard.authorize(root, path)
  defp confined(_root, _path), do: {:error, Error.new(:validation, "path is required")}

  defp image_mime(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> {:ok, "image/png"}
      ".jpg" -> {:ok, "image/jpeg"}
      ".jpeg" -> {:ok, "image/jpeg"}
      ".gif" -> {:ok, "image/gif"}
      ".webp" -> {:ok, "image/webp"}
      _ -> {:error, Error.new(:validation, "unsupported image type")}
    end
  end

  defp output_text(output) when is_list(output), do: Enum.join(output, "\n")
  defp output_text(output) when is_binary(output), do: output
  defp output_text(_), do: ""
  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp contract_attrs(context) do
    backend_context = %{family: :local, context: context}

    [
      contract(
        "exec_command",
        "Runs a command in a PTY, returning output or a session ID for ongoing interaction.",
        exec_schema(),
        backend_context,
        false
      ),
      contract(
        "write_stdin",
        "Writes characters to an existing unified exec session and returns recent output.",
        stdin_schema(),
        backend_context,
        false
      ),
      %{
        name: "apply_patch",
        description:
          "The `apply_patch` tool can be used to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.",
        input_kind: :custom,
        format: %{
          "type" => "grammar",
          "syntax" => "lark",
          "definition" => @apply_patch_grammar
        },
        backend: Backplane.AgentRuntime.Codex.Backend,
        backend_context: backend_context,
        safety: safety(false)
      },
      contract("update_plan", "Updates the task plan.", plan_schema(), backend_context, false),
      contract(
        "view_image",
        "View a local image file from the filesystem when visual inspection is needed.",
        image_schema(),
        backend_context,
        true
      ),
      contract(
        "clock::curr_time",
        "Return the current time in UTC.",
        empty_schema(),
        backend_context,
        true
      ),
      contract(
        "clock::sleep",
        "Pause execution for a specified duration.",
        sleep_schema(),
        backend_context,
        false
      )
    ]
  end

  defp configured?(contract, context) do
    name = Contract.canonical_name(Map.get(contract, :namespace), contract.name)

    case name do
      name when name in ["exec_command", "write_stdin"] ->
        is_map(Map.get(context, :command)) and is_map(Map.get(context, :caller)) and
          is_binary(Map.get(context, :workspace)) and is_pid(Map.get(context, :session_registry))

      name when name in ["apply_patch", "view_image"] ->
        is_binary(Map.get(context, :workspace))

      "update_plan" ->
        is_pid(Map.get(context, :plan))

      name when name in ["clock::curr_time", "clock::sleep"] ->
        true
    end
  end

  defp contract(name, description, schema, backend_context, read_only) do
    {:ok, {namespace, name}} = Contract.split_name(name)

    %{
      namespace: namespace,
      name: name,
      description: description,
      schema: schema,
      backend: Backplane.AgentRuntime.Codex.Backend,
      backend_context: backend_context,
      safety: safety(read_only)
    }
  end

  defp safety(read_only),
    do: %{read_only: read_only, retry_safe: read_only, parallel_safe: read_only}

  defp exec_schema do
    object_schema(
      %{
        "cmd" => %{"type" => "string"},
        "workdir" => %{"type" => "string"},
        "tty" => %{"type" => "boolean"},
        "yield_time_ms" => %{"type" => "number"},
        "max_output_tokens" => %{"type" => "number"},
        "shell" => %{"type" => "string"},
        "login" => %{"type" => "boolean"},
        "sandbox_permissions" => %{
          "type" => "string",
          "enum" => ["use_default", "require_escalated"]
        },
        "justification" => %{"type" => "string"},
        "prefix_rule" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      ["cmd"]
    )
  end

  defp stdin_schema do
    object_schema(
      %{
        "session_id" => %{"type" => "number"},
        "chars" => %{"type" => "string"},
        "yield_time_ms" => %{"type" => "number"},
        "max_output_tokens" => %{"type" => "number"}
      },
      ["session_id"]
    )
  end

  defp plan_schema do
    object_schema(
      %{
        "explanation" => %{"type" => "string"},
        "plan" => %{
          "type" => "array",
          "items" =>
            object_schema(
              %{
                "step" => %{"type" => "string"},
                "status" => %{
                  "type" => "string",
                  "enum" => ["pending", "in_progress", "completed"]
                }
              },
              ["step", "status"]
            )
        }
      },
      ["plan"]
    )
  end

  defp image_schema do
    object_schema(
      %{
        "path" => %{"type" => "string"},
        "detail" => %{"type" => "string", "enum" => ["high", "original"]}
      },
      ["path"]
    )
  end

  defp empty_schema, do: object_schema(%{}, nil)

  defp sleep_schema,
    do: object_schema(%{"duration_ms" => %{"type" => "number"}}, ["duration_ms"])

  defp object_schema(properties, required) do
    %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    |> then(fn schema -> if required, do: Map.put(schema, "required", required), else: schema end)
  end
end
