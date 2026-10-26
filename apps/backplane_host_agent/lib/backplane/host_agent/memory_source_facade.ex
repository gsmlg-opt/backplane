defmodule Backplane.HostAgent.MemorySourceFacade do
  @moduledoc "Local non-LLM source transport; profile labels never replace authenticated authority."
  alias Backplane.HostAgent.Memory.{Access, SourceCommands, Syncer}
  alias Backplane.MemorySourceContract, as: Contract

  def methods, do: ~w(source_capabilities source_mutate source_reconcile source_status)

  def call("source_capabilities", args, context) when is_map(args) do
    with true <-
           Map.keys(args) -- ["memory_access_id", "integration"] == [] and
             Map.get(args, "integration", "hermes") in ["hermes", "openclaw"],
         true <-
           not Map.has_key?(args, "memory_access_id") or Contract.uuid?(args["memory_access_id"]),
         %{} = status <- Access.status(server(context)) do
      integration = Map.get(args, "integration", "hermes")

      extensions =
        if integration == "openclaw",
          do: ~w(memory_commands.v2 memory_sources.v1 openclaw_source.v1),
          else: ~w(memory_commands.v2 memory_sources.v1)

      capture_contract = integration <> "_capture.v1"
      id = args["memory_access_id"] || status.default_access_id
      entry = Enum.find(status.accesses, &(&1.access_id == id))

      binding =
        if entry,
          do: %{
            "access_id" => entry.access_id,
            "authority_version" => entry.authority_version,
            "partition" => entry.partition
          }

      source_error =
        cond do
          not status.negotiated ->
            "not_negotiated"

          status.blocked or status.global_fenced or is_nil(entry) ->
            "unauthorized"

          entry.status == "fenced" or
              not Access.allowed_operation?(:source, entry.capabilities) ->
            "unauthorized"

          not Enum.all?(extensions, &(&1 in status.extensions)) ->
            "unsupported_capability"

          true ->
            nil
        end

      ready = is_nil(source_error)

      default = Enum.find(status.accesses, &(&1.access_id == status.default_access_id))

      capture_binding =
        if default,
          do: %{
            "access_id" => default.access_id,
            "authority_version" => default.authority_version,
            "partition" => default.partition
          }

      capture_runtime = Application.get_env(:backplane_host_agent, :capture_runtime)
      capture_configured = is_map(capture_runtime) and not is_nil(capture_runtime[:spool])

      capture_error =
        cond do
          not status.negotiated ->
            "not_negotiated"

          id != status.default_access_id ->
            "capture_binding_mismatch"

          integration == "openclaw" and capture_contract not in status.extensions ->
            "unsupported_capability"

          not capture_configured ->
            "capture_unavailable"

          capture_contract not in status.extensions ->
            "unsupported_capability"

          ready != true ->
            "capture_unavailable"

          true ->
            nil
        end

      {:ok,
       %{
         "protocol" => Contract.protocol(),
         "supported" => true,
         "contracts" =>
           [Contract.protocol(), capture_contract] ++
             if(integration == "openclaw", do: ["openclaw_source.v1"], else: []),
         "integration" => integration,
         "negotiated" => status.extensions,
         "ready" => ready == true,
         "source_error" => source_error,
         "binding" => binding,
         "binding_fingerprint" => if(binding, do: Contract.digest(binding)),
         "capture_binding" => capture_binding,
         "capture_binding_fingerprint" =>
           if(capture_binding, do: Contract.digest(capture_binding)),
         "capture_ready" => is_nil(capture_error),
         "capture_error" => capture_error,
         "limits" => Contract.limits()
       }}
    else
      false -> {:error, :invalid_arguments}
      error -> error
    end
  end

  def call(method, args, context)
      when method in ~w(source_mutate source_reconcile source_status) do
    with {:ok, args} <- Contract.validate(method, args),
         :ok <- Backplane.HostAgent.MemoryProxy.authorize_command(),
         :ok <- integration_supported(args, context),
         {:ok, target, ticket} <- Access.begin_request(selector(args), :source, server(context)) do
      args = Map.delete(args, "memory_access_id")

      result =
        if method == "source_status" do
          Access.run_local(
            target,
            :source,
            &SourceCommands.status(&1, args["source"], args["event_id"]),
            server(context)
          )
        else
          with {:ok, _} <-
                 Access.run_local(
                   target,
                   :source,
                   &SourceCommands.enqueue(&1, method, args, context[:agent_id] || "hermes"),
                   server(context)
                 ) do
            opts =
              [store: target.store, access_server: server(context)] ++
                Map.get(context, :sync_opts, [])

            # Durability precedes this bounded attempt. A timeout cannot change
            # the journaled event or cause append-only fallback.
            _ = Syncer.drain_shared(opts)

            Access.run_local(
              target,
              :source,
              &SourceCommands.status(&1, args["source"], args["event_id"]),
              server(context)
            )
          end
        end

      finish(target, ticket, result, context)
    end
  end

  def call(_, _, _), do: {:error, :invalid_arguments}

  defp finish(target, ticket, {:ok, result}, context) do
    reply = %{
      "access" => Access.claim(target),
      "partition" => target.partition,
      "result" => result
    }

    with {:ok, permitted, result} <- Access.finish_request(ticket, {:ok, reply}, server(context)),
         do: Access.run_local(permitted, :source, fn _ -> {:ok, result} end, server(context))
  end

  defp finish(_target, ticket, error, context) do
    _ = Access.finish_request(ticket, error, server(context))
    error
  end

  defp integration_supported(%{"source" => %{"integration" => "openclaw"}}, context) do
    case Access.status(server(context)) do
      %{extensions: extensions} ->
        if "openclaw_source.v1" in extensions, do: :ok, else: {:error, :unsupported_capability}

      _ ->
        {:error, :access_owner_unavailable}
    end
  end

  defp integration_supported(_, _), do: :ok

  defp selector(%{"memory_access_id" => id}), do: {:access_id, id}
  defp selector(_), do: :default
  defp server(context), do: Map.get(context, :access_server, Access)
end
