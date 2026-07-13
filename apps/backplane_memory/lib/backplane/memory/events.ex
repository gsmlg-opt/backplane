defmodule Backplane.Memory.Events do
  alias Backplane.Memory.Events.{Types, Event}

  def append(attrs) do
    with {:ok, normalized} <- Types.normalize(attrs),
         {:ok, filtered} <- Backplane.Memory.Privacy.Filter.apply_event(normalized) do
      allowed =
        for {k, v} <- filtered, k in (Event.__schema__(:fields) ++ [:id]), into: %{}, do: {k, v}

      {:ok, struct(Event, allowed)}
    end
  end

  def append_batch(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn a, {:ok, acc} ->
      case append(a) do
        {:ok, e} -> {:cont, {:ok, [e | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, es} -> {:ok, Enum.reverse(es)}
      e -> e
    end
  end

  def append_batch(_), do: {:error, :invalid_attributes}
end
