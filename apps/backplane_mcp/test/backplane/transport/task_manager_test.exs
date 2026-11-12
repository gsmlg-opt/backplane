defmodule Backplane.Transport.TaskManagerTest do
  use ExUnit.Case, async: false

  alias Backplane.Transport.TaskManager

  defp auth(extra \\ %{}) do
    Map.merge(
      %{kind: :client_token, subject: nil, client_id: "client-1", scopes: ["*"]},
      extra
    )
  end

  test "a task is retrievable only from the resource that created it" do
    root = auth(%{resource: :mcp})
    endpoint = auth(%{resource: {:endpoint, "chatgpt", :mcp}})
    other = auth(%{resource: {:endpoint, "other", :mcp}})

    {:ok, task_id} = TaskManager.create("nope::missing", %{}, nil, root)

    assert TaskManager.get(task_id, root)
    refute TaskManager.get(task_id, endpoint)

    {:ok, endpoint_task} = TaskManager.create("nope::missing", %{}, nil, endpoint)
    assert TaskManager.get(endpoint_task, endpoint)
    refute TaskManager.get(endpoint_task, root)
    refute TaskManager.get(endpoint_task, other)
  end

  test "an auth map without a resource behaves as the root resource" do
    {:ok, task_id} = TaskManager.create("nope::missing", %{}, nil, auth())

    assert TaskManager.get(task_id, auth(%{resource: :mcp}))
    assert TaskManager.get(task_id, auth())
  end
end
