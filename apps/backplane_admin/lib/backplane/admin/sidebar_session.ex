defmodule Backplane.Admin.SidebarSession do
  @moduledoc false

  alias Phoenix.SessionProcess

  def read(session_id) do
    with {:ok, _pid} <- ensure_session(session_id) do
      read_state(session_id)
    end
  end

  def put(session_id, collapsed) when is_boolean(collapsed) do
    with {:ok, _pid} <- ensure_session(session_id),
         :ok <- SessionProcess.cast(session_id, {:put, :sidebar_collapsed, collapsed}) do
      # The read follows the cast from the same caller, acknowledging the write.
      read_state(session_id)
    end
  end

  defp ensure_session(session_id) do
    case SessionProcess.find_session(session_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        case SessionProcess.start_session(session_id) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end

  defp read_state(session_id) do
    case SessionProcess.get_state(session_id) do
      state when is_map(state) -> {:ok, Map.get(state, :sidebar_collapsed, false)}
      {:error, _reason} = error -> error
    end
  end
end
