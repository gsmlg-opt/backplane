defmodule Backplane.Memory.Events.Types do
  @min_importance -2_147_483_648
  @max_importance 2_147_483_647
  @types ~w(session.started session.ended conversation.user_message conversation.agent_message agent.run.started agent.run.completed agent.run.failed tool.call.started tool.call.completed tool.call.failed task.created task.updated task.completed memory.recalled heartbeat.triggered dream.started dream.completed schedule.triggered legacy.observation)
  @aliases %{
    "type" => :event_type,
    "event_type" => :event_type,
    "stream" => :stream_id,
    "stream_id" => :stream_id,
    "session_id" => :session_id,
    "identity" => :identity_id,
    "identity_id" => :identity_id,
    "content" => :content,
    "payload" => :payload,
    "namespace" => :namespace,
    "importance" => :importance,
    "occurred_at" => :occurred_at,
    "id" => :id,
    "project" => :project,
    "agent_id" => :agent_id,
    "host_id" => :host_id,
    "client_id" => :client_id,
    "run_id" => :run_id,
    "tool_name" => :tool_name,
    "actor_type" => :actor_type,
    "role" => :role,
    "status" => :status,
    "correlation_id" => :correlation_id,
    "causation_id" => :causation_id,
    "idempotency_key" => :idempotency_key
  }
  def accepted_types, do: @types

  def normalize(attrs) when is_map(attrs) do
    with {:ok, m} <- keys(attrs),
         {:ok, t} <- type(m),
         :ok <- valid_type(t),
         :ok <- identity(m),
         :ok <- payload(m),
         {:ok, m} <- defaults(m) do
      {:ok, m}
    end
  end

  def normalize(_), do: {:error, :invalid_attributes_type}

  defp keys(m),
    do:
      Enum.reduce_while(m, {:ok, %{}}, fn {k, v}, {:ok, a} ->
        key = normalize_key(k)

        cond do
          match?({:invalid_key, _}, key) -> {:halt, {:error, key}}
          Map.has_key?(a, key) and a[key] != v -> {:halt, {:error, :conflicting_keys}}
          true -> {:cont, {:ok, Map.put(a, key, v)}}
        end
      end)

  defp type(%{event_type: t}) when is_binary(t), do: {:ok, t}
  defp type(_), do: {:error, :invalid_event_type}
  defp valid_type(t), do: if(t in @types, do: :ok, else: {:error, :invalid_event_type})

  defp normalize_key(k) when is_atom(k), do: k
  defp normalize_key(k) when is_binary(k), do: Map.get(@aliases, String.downcase(k), k)
  defp normalize_key(k), do: {:invalid_key, k}
  defp identity(%{stream_id: s}) when is_binary(s) and byte_size(s) > 0, do: :ok
  defp identity(%{stream_id: _}), do: {:error, :missing_identity}
  defp identity(%{session_id: s}) when is_binary(s) and byte_size(s) > 0, do: :ok
  defp identity(_), do: {:error, :missing_identity}

  defp payload(%{payload: p}) when is_map(p) and not is_struct(p) do
    if json_safe?(p), do: :ok, else: {:error, :invalid_payload}
  end

  defp payload(%{payload: _}), do: {:error, :invalid_payload}
  defp payload(_), do: :ok

  defp json_safe?(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: true
  defp json_safe?(v) when is_list(v), do: json_safe_list?(v)
  defp json_safe?(v) when is_struct(v), do: false

  defp json_safe?(v) when is_map(v),
    do: Enum.all?(v, fn {k, value} -> is_binary(k) and json_safe?(value) end)

  defp json_safe?(_), do: false

  defp json_safe_list?([]), do: true
  defp json_safe_list?([head | tail]), do: json_safe?(head) and json_safe_list?(tail)
  defp json_safe_list?(_), do: false

  defp defaults(m) do
    m =
      if Map.has_key?(m, :stream_id),
        do: m,
        else: Map.put(m, :stream_id, "session:" <> m.session_id)

    m =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          namespace: "private",
          payload: %{},
          importance: 0,
          occurred_at: DateTime.utc_now()
        },
        m
      )

    with {:ok, id} <- Ecto.UUID.cast(m.id),
         {:ok, m} <- causation_uuid(m),
         {:ok, dt} <- datetime(m.occurred_at),
         true <- valid_importance?(m.importance) do
      {:ok, %{m | id: id, occurred_at: dt}}
    else
      {:error, :invalid_time} -> {:error, :invalid_time}
      {:error, :invalid_uuid} -> {:error, :invalid_uuid}
      :error -> {:error, :invalid_uuid}
      false -> {:error, :invalid_importance}
    end
  end

  defp causation_uuid(%{causation_id: nil} = m), do: {:ok, m}

  defp causation_uuid(%{causation_id: causation_id} = m) do
    case Ecto.UUID.cast(causation_id) do
      {:ok, causation_id} -> {:ok, %{m | causation_id: causation_id}}
      :error -> :error
    end
  end

  defp causation_uuid(m), do: {:ok, m}

  defp valid_importance?(importance) when is_integer(importance),
    do: importance >= @min_importance and importance <= @max_importance

  defp valid_importance?(_), do: false

  defp datetime(%DateTime{} = d), do: {:ok, DateTime.shift_zone!(d, "Etc/UTC")}

  defp datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, d, _} -> {:ok, DateTime.shift_zone!(d, "Etc/UTC")}
      _ -> {:error, :invalid_time}
    end
  end

  defp datetime(_), do: {:error, :invalid_time}
end
