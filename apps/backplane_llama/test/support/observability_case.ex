defmodule Backplane.LLM.ObservabilityCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using opts do
    quote do
      use BackplaneLlama.DataCase, unquote(opts)
      import Backplane.LLM.ObservabilityCase

      alias Backplane.LLM.{LogWriter, ProxyRequest}
      alias Backplane.Observability.Buffer

      setup tags do
        if tags[:observability_v2] do
          enable_observability_v2!()
          start_observability_v2!(tags)

          on_exit(fn ->
            Backplane.LLM.LogWriter.detach()
            reset_observability_v2!()
          end)
        end

        :ok
      end
    end
  end

  @doc false
  def enable_observability_v2! do
    Application.put_env(:backplane_telemetry, :observability_v2_test_disabled, false)
    Application.put_env(:backplane_telemetry, :observability_v2_enabled, true)
    Application.put_env(:backplane_telemetry, :observability_v2_llm_write, true)
  end

  @doc false
  def disable_observability_v2! do
    Application.put_env(:backplane_telemetry, :observability_v2_enabled, false)
    Application.put_env(:backplane_telemetry, :observability_v2_llm_write, false)
    Application.put_env(:backplane_telemetry, :observability_v2_test_disabled, true)
  end

  @doc false
  def reset_observability_v2! do
    Application.put_env(:backplane_telemetry, :observability_v2_enabled, false)
    Application.put_env(:backplane_telemetry, :observability_v2_llm_write, false)
    Application.delete_env(:backplane_telemetry, :observability_v2_test_disabled)
  end

  @doc false
  def start_observability_v2!(tags \\ []) do
    capacity = Map.get(tags, :buffer_capacity, 100)

    case Process.whereis(:llm_proxy) do
      nil ->
        start_supervised!(
          {Backplane.Observability.Buffer, [name: :llm_proxy, capacity: capacity]}
        )

      _ ->
        :ok
    end

    writer_opts = [
      batch_size: Map.get(tags, :batch_size, 50),
      flush_interval_ms: Map.get(tags, :flush_interval_ms, 60_000)
    ]

    case Process.whereis(Backplane.LLM.LogWriter) do
      nil ->
        start_supervised!({Backplane.LLM.LogWriter, writer_opts})

      _ ->
        Backplane.LLM.LogWriter.detach()
        Backplane.LLM.LogWriter.attach()
        :ok
    end
  end

  @doc false
  def flush_logs! do
    Backplane.LLM.LogWriter.flush()
  end

  @doc false
  def latest_log do
    import Ecto.Query

    Backplane.Repo.one(
      from(l in Backplane.LLM.ProxyRequest, order_by: [desc: l.inserted_at], limit: 1)
    )
  end

  @doc false
  def log_for_model(model) do
    import Ecto.Query

    Backplane.Repo.one(
      from(l in Backplane.LLM.ProxyRequest,
        where: l.requested_model == ^model,
        order_by: [desc: l.inserted_at],
        limit: 1
      )
    )
  end
end
