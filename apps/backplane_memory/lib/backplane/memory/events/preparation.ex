defmodule Backplane.Memory.Events.Preparation do
  @moduledoc false

  alias Backplane.Memory.Events.{Event, Types}

  def prepare(attrs) do
    with {:ok, normalized} <- Types.normalize(attrs),
         {:ok, filtered} <- Backplane.Memory.Privacy.Filter.apply_event(normalized) do
      allowed_fields = Event.__schema__(:fields) ++ [:id]

      allowed =
        for {key, value} <- filtered, key in allowed_fields, into: %{} do
          {key, value}
        end

      {:ok, struct(Event, allowed)}
    end
  end

  def prepare_batch(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, events} ->
      case prepare(attrs) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare_batch(_value), do: {:error, :invalid_attributes}
end
