defmodule Backplane.AgentRuntime.Codex.Commands do
  @moduledoc """
  Owner/incarnation-scoped native command inspection.

  Pass the same trusted context used to construct a Codex local profile. Command
  IDs come from `exec_command`/`write_stdin` results. Logs are non-consuming;
  `poll/3` alone advances a separate inspection byte cursor, initially zero.
  Neither operation drains the original `write_stdin` delivery cursor. A poll
  that observes confirmed terminal cleanup settles the existing native session
  and retains its final snapshot, as ordinary terminal collection does.

  Reads return at most `:max_bytes` (default 65,536, maximum 1,048,576), with a
  byte cursor, total size and truncation flag. Byte ranges can split UTF-8
  sequences. Pipe output retains the existing normalized line representation.
  Finalized logs are snapshots taken during ordinary terminal collection and
  remain available independently of backend job retention. Registry options
  `:command_history_count`, `:command_history_bytes`, `:command_history_ttl`
  bound recent records (defaults 64, 16 MiB, 300,000 ms). Expired or evicted
  records return `:not_found`; active cleanup obligations are never evicted.
  `started_at` is the admission timestamp; `finished_at` is the backend's terminal
  timestamp when available, otherwise nil. Times are Unix milliseconds.

  `remove/2` and `clear_finished/1` remove finalized inspection only. They never
  terminate a command, remove an active session, or erase cleanup receipts.
  This API does not add model-callable tools or bypass tool admission.
  """
  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Codex.ResourceRegistry

  @max_bytes 1_048_576

  @doc "List current and retained commands for the context's exact owner/incarnation."
  def list(context) do
    with {:ok, registry, owner, incarnation} <- identity(context),
         {:ok, records} <- ResourceRegistry.command_records(registry, owner, incarnation) do
      Enum.reduce_while(records, {:ok, []}, fn record, {:ok, collected} ->
        case refresh(context, registry, owner, incarnation, record) do
          {:ok, current} ->
            {:cont, {:ok, collected ++ [public(current)]}}

          {:error, %Error{class: :resource_conflict}} ->
            {:cont, {:ok, collected ++ [public(record)]}}

          {:error, %Error{class: :not_found}} ->
            {:cont, {:ok, collected ++ [public(Map.put(record, :status, :unavailable))]}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  @doc "Inspect current status and retained public metadata without consuming output."
  def inspect(context, id) do
    with {:ok, record, _registry, _owner, _incarnation} <- read_record(context, id) do
      {:ok, public(record)}
    end
  end

  @doc "Read a bounded non-consuming byte range, starting at `:cursor` (default zero)."
  def log(context, id, opts \\ []), do: read_output(context, id, opts, false)

  @doc "Read and advance the independent inspection byte cursor."
  def poll(context, id, opts \\ []), do: read_output(context, id, opts, true)

  @doc "Remove only a finalized inspection record; active commands return resource_conflict."
  def remove(context, id) do
    with {:ok, registry, owner, incarnation} <- identity(context),
         :ok <- valid_id(id) do
      ResourceRegistry.remove_command(registry, id, owner, incarnation)
    end
  end

  @doc "Clear the context owner's finalized records and return the number removed."
  def clear_finished(context) do
    with {:ok, registry, owner, incarnation} <- identity(context) do
      ResourceRegistry.clear_commands(registry, owner, incarnation)
    end
  end

  defp read_output(context, id, opts, poll?) do
    with {:ok, opts} <- output_options(opts),
         {:ok, record, registry, owner, incarnation} <- read_record(context, id),
         :ok <- maybe_finalize(registry, id, owner, incarnation, record, poll?) do
      ResourceRegistry.command_output(
        registry,
        id,
        owner,
        incarnation,
        record,
        Keyword.put(opts, :poll, poll?)
      )
    end
  end

  defp maybe_finalize(
         registry,
         id,
         owner,
         incarnation,
         %{finalized: false, cleanup_status: :confirmed, status: status} = record,
         true
       )
       when status != :running do
    case ResourceRegistry.archive_command(
           registry,
           id,
           owner,
           incarnation,
           Map.take(record, [
             :output,
             :status,
             :exit_status,
             :termination_status,
             :cleanup_status,
             :output_limit_exceeded?,
             :finished_at
           ])
         ) do
      :ok ->
        :ok

      {:error, %Error{class: :not_found}} ->
        case ResourceRegistry.command_record(registry, id, owner, incarnation) do
          {:ok, %{finalized: true}} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp maybe_finalize(_registry, _id, _owner, _incarnation, _record, _poll?), do: :ok

  defp read_record(context, id) do
    with {:ok, registry, owner, incarnation} <- identity(context),
         :ok <- valid_id(id),
         {:ok, record} <- ResourceRegistry.command_record(registry, id, owner, incarnation),
         {:ok, record} <- refresh(context, registry, owner, incarnation, record) do
      {:ok, record, registry, owner, incarnation}
    end
  end

  defp refresh(_context, _registry, _owner, _incarnation, %{finalized: true} = record),
    do: {:ok, record}

  defp refresh(%{command: command}, registry, owner, incarnation, record) do
    with {:ok, session} <-
           ResourceRegistry.fetch_session(registry, record.command_id, owner, incarnation),
         true <- is_map(session.job),
         {:ok, result} <-
           Command.read(command, %{owner_run_id: owner, incarnation: incarnation}, session.job,
             cursor: 0
           ) do
      {:ok, Map.merge(record, snapshot(result))}
    else
      false ->
        {:ok, record}

      {:error, %Error{class: :not_found}} = error ->
        case ResourceRegistry.command_record(registry, record.command_id, owner, incarnation) do
          {:ok, %{finalized: true} = retained} -> {:ok, retained}
          _ -> error
        end

      error ->
        error
    end
  end

  defp refresh(_context, _registry, _owner, _incarnation, _record),
    do: {:error, Error.new(:unsupported_capability, "command backend is not configured")}

  @doc false
  def snapshot(result) do
    output =
      case result.output do
        bytes when is_binary(bytes) -> bytes
        lines when is_list(lines) -> Enum.join(lines, "\n")
      end

    result
    |> Map.take([
      :status,
      :exit_status,
      :termination_status,
      :cleanup_status,
      :output_limit_exceeded?,
      :finished_at
    ])
    |> Map.put(:output, output)
  end

  defp identity(context) when is_map(context) do
    registry = Map.get(context, :session_registry)

    {owner, incarnation} =
      case Map.get(context, :resource_owner) do
        %{owner_id: owner, incarnation: incarnation} ->
          {owner, incarnation}

        _ ->
          owner =
            case Map.get(context, :caller) do
              %{run_id: id} -> id
              _ -> nil
            end

          {owner, Map.get(context, :incarnation, 1)}
      end

    if is_pid(registry) and is_binary(owner) and owner != "" and
         is_integer(incarnation) and incarnation > 0,
       do: {:ok, registry, owner, incarnation},
       else:
         {:error,
          Error.new(:validation, "trusted command registry, owner and incarnation are required")}
  end

  defp identity(_), do: {:error, Error.new(:validation, "command context is required")}

  defp public(record),
    do: Map.drop(record, [:output, :poll_cursor, :retained_at, :owner_id, :incarnation])

  defp valid_id(id) when is_integer(id) and id > 0, do: :ok
  defp valid_id(_), do: {:error, Error.new(:validation, "command_id must be positive")}

  defp output_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      cursor = Keyword.get(opts, :cursor, 0)
      bytes = Keyword.get(opts, :max_bytes, 65_536)

      if is_integer(cursor) and cursor >= 0 and is_integer(bytes) and bytes in 1..@max_bytes,
        do: {:ok, [cursor: cursor, max_bytes: bytes]},
        else:
          {:error, Error.new(:validation, "cursor and max_bytes are outside supported bounds")}
    else
      {:error, Error.new(:validation, "command read options must be a keyword list")}
    end
  end

  defp output_options(_),
    do: {:error, Error.new(:validation, "command read options must be a keyword list")}
end
