defmodule EmptyToolBackend do
  def execute(_operation), do: {:ok, %{text: "ok"}}
end

defmodule EmptyTool do
  @moduledoc """
  Clean-consumer fixture proving an inert runtime with no configured tools.
  """

  alias Backplane.AgentRuntime.{Error, ToolCatalog}
  alias Backplane.AgentRuntime.Tools

  def verify! do
    nil = Process.whereis(Backplane.AgentRuntime.Tools.LocalResource)
    nil = Process.whereis(Backplane.AgentRuntime.Tools.LocalCommand)
    {:ok, tools} = Tools.new(%{})
    [] = Tools.available_tools(tools)

    valid = %{
      tool_name: "read",
      tool_revision: 1,
      schema: %{"type" => "object"},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: EmptyToolBackend,
      backend_context: %{}
    }

    second = %{
      tool_name: "write",
      tool_revision: 2,
      schema: %{"type" => "object"},
      safety: %{read_only: false, retry_safe: false, parallel_safe: false},
      backend: EmptyToolBackend,
      backend_context: %{}
    }

    rejected = %{
      tool_name: "legacy",
      tool_revision: 2,
      schema: %{"$schema" => "https://example.invalid"},
      safety: %{read_only: true, retry_safe: true, parallel_safe: false},
      backend: EmptyToolBackend,
      backend_context: %{}
    }

    {:ok, bundle} =
      ToolCatalog.admit_batch([valid, second, rejected],
        mode: :quarantine,
        run_id: "fixture",
        authority: %{
          caller: "fixture",
          run_id: "fixture",
          grants: ["read", "write", "legacy"],
          tool_revisions: %{"read" => 1, "write" => 2, "legacy" => 2}
        }
      )

    ["read", "write"] = bundle.accepted
    %{"read" => 1, "write" => 2} = bundle.authority.tool_revisions

    [%{name: "legacy", descriptor_revision: 2, error: %Error{class: :unsupported_capability}}] =
      bundle.rejected

    {:ok, %{accepted: [], tools: [], authority: %{grants: []}}} =
      ToolCatalog.admit_batch([])

    {:error, %Error{class: :unsupported_capability}} =
      Tools.memory_search(tools, %{memory_scope: "task"}, %{scope: "task"})

    :ok
  end
end
