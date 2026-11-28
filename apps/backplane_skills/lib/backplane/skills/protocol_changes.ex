defmodule Backplane.Skills.ProtocolChanges do
  @moduledoc "Durable Skill Protocol generation and committed database-change notifications."

  use GenServer

  alias Backplane.Repo

  @database_channel "backplane_skill_protocol_changed"
  @topic "skills:protocol"
  @connection_keys [
    :url,
    :hostname,
    :port,
    :database,
    :username,
    :password,
    :socket_dir,
    :ssl,
    :ssl_opts,
    :parameters,
    :connect_timeout,
    :socket_options,
    :types
  ]

  @doc "Returns the committed generation in the caller's database context."
  @spec current() :: {:ok, String.t()} | {:error, term()}
  def current do
    with :ok <- ready(),
         {:ok, %{rows: [[generation]]}} <-
           Repo.query("SELECT generation::text FROM skill_protocol_state WHERE id = 1", []) do
      {:ok, generation}
    else
      {:ok, _result} -> {:error, :state_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns changed skill IDs since a generation, or a reset when the durable history cannot be reused."
  @spec since(String.t() | nil) ::
          {:ok, %{generation: String.t(), skill_ids: [String.t()]}}
          | {:reset, String.t()}
          | {:error, term()}
  def since(previous) when is_binary(previous) do
    with :ok <- ready(),
         {:ok, %{rows: rows}} <-
           Repo.query(
             """
             WITH anchor AS (
               SELECT position FROM skill_protocol_changes WHERE generation::text = $1
               UNION ALL
               SELECT position - 1 FROM skill_protocol_changes WHERE previous_generation::text = $1
             ), delta AS (
               SELECT * FROM skill_protocol_changes
               WHERE position > (SELECT min(position) FROM anchor)
             )
             SELECT s.generation::text, d.generation::text, d.previous_generation::text,
                    d.skill_ids, d.reset
             FROM skill_protocol_state s LEFT JOIN delta d ON true
             WHERE s.id = 1 ORDER BY d.position
             """,
             [previous]
           ) do
      delta(rows, previous)
    end
  end

  def since(_previous) do
    with {:ok, generation} <- current(), do: {:reset, generation}
  end

  defp delta([], _previous), do: {:error, :state_unavailable}

  defp delta([[current, _generation, _previous, _ids, _reset] | _] = rows, previous) do
    if current == previous do
      {:ok, %{generation: current, skill_ids: []}}
    else
      rows
      |> Enum.reduce_while({previous, MapSet.new()}, fn
        [_current, generation, expected, ids, false], {expected, accumulated}
        when is_list(ids) ->
          ids = Enum.reduce(ids, accumulated, &MapSet.put(&2, &1))

          if MapSet.size(ids) <= 512,
            do: {:cont, {generation, ids}},
            else: {:halt, :reset}

        _row, _accumulated ->
          {:halt, :reset}
      end)
      |> case do
        {^current, ids} ->
          {:ok, %{generation: current, skill_ids: ids |> MapSet.to_list() |> Enum.sort()}}

        _ ->
          {:reset, current}
      end
    end
  end

  @doc "Subscribes the caller before checking that the database listener is ready."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    with :ok <- Phoenix.PubSub.subscribe(Backplane.PubSub, @topic), do: ready()
  catch
    :exit, _reason -> {:error, :listener_unavailable}
  end

  @doc "Returns the listener PID so consumers can monitor its lifetime."
  @spec listener() :: pid() | nil
  def listener, do: Process.whereis(__MODULE__)

  @doc false
  def topic, do: @topic

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    opts =
      Repo.config()
      |> Keyword.take(@connection_keys)
      |> Keyword.merge(sync_connect: true, auto_reconnect: false)

    with {:ok, connection} <- Postgrex.Notifications.start_link(opts),
         {:ok, ref} <- Postgrex.Notifications.listen(connection, @database_channel) do
      Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, :skill_protocol_changed)
      {:ok, %{connection: connection, listen_ref: ref}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:ready, _from, state) do
    result = if Process.alive?(state.connection), do: :ok, else: {:error, :listener_unavailable}
    {:reply, result, state}
  end

  @impl true
  def handle_info(
        {:notification, connection, ref, @database_channel, _payload},
        %{connection: connection, listen_ref: ref} = state
      ) do
    Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, :skill_protocol_changed)
    {:noreply, state}
  end

  def handle_info({:EXIT, connection, _reason}, %{connection: connection} = state) do
    Phoenix.PubSub.broadcast(Backplane.PubSub, @topic, :skill_protocol_unavailable)
    {:stop, :database_listener_closed, state}
  end

  defp ready do
    GenServer.call(__MODULE__, :ready)
  catch
    :exit, _reason -> {:error, :listener_unavailable}
  end
end
