defmodule BackplaneWeb.HostAgentMemorySync do
  @moduledoc """
  Default hub-side adapter for host-agent memory sync protocol events.
  """

  def apply_sync_item(host, %{"op" => "remember"} = item) do
    service = Application.get_env(:backplane_web, :memory_service, BackplaneMemory.Service)

    args =
      item
      |> Map.put("host_id", host.id)
      |> Map.put_new("type", "episodic")

    case service.handle_remember(args) do
      {:ok, result} ->
        canonical_id = result[:id] || result["id"]
        status = if canonical_id == item["id"], do: :ok, else: :duplicate
        {:ok, %{status: status, canonical_id: canonical_id}}

      {:error, reason} ->
        {:error, :validation, reason}
    end
  end

  def apply_sync_item(_host, %{"op" => "forget"} = item) do
    service = Application.get_env(:backplane_web, :memory_service, BackplaneMemory.Service)
    id = item["remote_id"] || item["id"]

    case service.handle_forget(%{"id" => id}) do
      {:ok, _result} -> {:ok, %{status: :ok, canonical_id: id}}
      {:error, reason} -> {:error, :validation, reason}
    end
  end

  def apply_sync_item(_host, _item), do: {:error, :validation, "unsupported memory sync op"}

  def facts_for_scope(_scope, _host_fact_set_hash), do: :unchanged

  def active_wipes(_scope), do: []

  def entitled_scopes(_host), do: MapSet.new()
end
