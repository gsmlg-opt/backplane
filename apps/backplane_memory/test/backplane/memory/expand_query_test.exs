defmodule Backplane.Memory.ExpandQueryTest do
  use Backplane.Memory.DataCase, async: false

  test "the exposed expansion tool returns classified provider failure without crashing" do
    previous = Application.fetch_env(:backplane_memory, :llm_module)
    Application.put_env(:backplane_memory, :llm_module, __MODULE__)

    on_exit(fn ->
      case previous do
        {:ok, module} -> Application.put_env(:backplane_memory, :llm_module, module)
        :error -> Application.delete_env(:backplane_memory, :llm_module)
      end
    end)

    assert {:error, {:llm_status, 503}} =
             Backplane.Memory.Service.trusted_call("memory::expand_query", %{"query" => "routing"})
  end

  def expand_query(_query), do: {:error, {:llm_status, 503}}
end
