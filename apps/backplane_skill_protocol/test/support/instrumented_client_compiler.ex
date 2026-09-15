defmodule Backplane.SkillProtocol.InstrumentedClientCompiler do
  @moduledoc false

  @production_module Backplane.SkillProtocol.Client
  @instrumented_module Backplane.SkillProtocol.StartupInstrumentedClient

  def compile! do
    source_path = Path.expand("../../lib/backplane/skill_protocol/client.ex", __DIR__)

    source_path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> instrument()
    |> Code.compile_quoted()
  end

  defp instrument({:defmodule, meta, [module_ast, [do: body]]}) do
    if Macro.expand(module_ast, __ENV__) != @production_module do
      raise "unexpected Client module AST"
    end

    {body, count} = Macro.postwalk(body, 0, &instrument_guardian/2)

    if count != 1 do
      raise "expected exactly one operation_guardian/4 definition, found #{count}"
    end

    {:defmodule, meta, [@instrumented_module, [do: body]]}
  end

  defp instrument(_ast), do: raise("unexpected Client module AST")

  defp instrument_guardian(
         {:defp, meta,
          [
            {:operation_guardian, _, [owner, _ref, transport, _request]} = head,
            [do: {:__block__, block_meta, statements}]
          ]},
         count
       ) do
    owner_monitor_index = assignment_index!(statements, :owner_monitor)
    worker_index = assignment_index!(statements, {:worker, :worker_monitor})

    {:=, _, [{{:worker, _, _} = worker, {:worker_monitor, _, _}}, _]} =
      Enum.fetch!(statements, worker_index)

    if owner_monitor_index >= worker_index do
      raise "operation guardian setup order changed"
    end

    before_owner_monitor =
      quote do
        unquote(transport).(
          {:startup_test_barrier, :before_owner_monitor, self(), unquote(owner)}
        )
      end

    after_worker_spawn =
      quote do
        unquote(transport).(
          {:startup_test_barrier, :after_worker_spawn, self(), unquote(owner), unquote(worker)}
        )
      end

    statements =
      statements
      |> List.insert_at(owner_monitor_index, before_owner_monitor)
      |> List.insert_at(worker_index + 2, after_worker_spawn)

    {{:defp, meta, [head, [do: {:__block__, block_meta, statements}]]}, count + 1}
  end

  defp instrument_guardian(ast, count), do: {ast, count}

  defp assignment_index!(statements, variable) when is_atom(variable) do
    assignment_index!(statements, fn
      {:=, _, [{^variable, _, _}, _]} -> true
      _ -> false
    end)
  end

  defp assignment_index!(statements, {left, right}) do
    assignment_index!(statements, fn
      {:=, _, [{{^left, _, _}, {^right, _, _}}, _]} -> true
      _ -> false
    end)
  end

  defp assignment_index!(statements, predicate) do
    case statements
         |> Enum.with_index()
         |> Enum.filter(fn {statement, _} -> predicate.(statement) end) do
      [{_statement, index}] -> index
      matches -> raise "expected one guardian assignment, found #{length(matches)}"
    end
  end
end
