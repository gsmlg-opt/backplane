defmodule Backplane.HostAgent.Memory.OpenClawBinding do
  @moduledoc "Pins admitted OpenClaw capture to the existing authenticated default access."
  alias Backplane.HostAgent.Memory.Access
  alias Backplane.MemorySourceContract, as: Contract

  @extensions ~w(memory_commands.v2 memory_sources.v1 openclaw_source.v1 openclaw_capture.v1)

  def current(server \\ Access) do
    case Access.status(server) do
      %{negotiated: true, blocked: false, global_fenced: false} = status ->
        with :ok <- extension_check(status.extensions),
             %{} = entry <-
               Enum.find(status.accesses, &(&1.access_id == status.default_access_id)),
             true <-
               entry.status != "fenced" and Access.allowed_operation?(:source, entry.capabilities) do
          binding = binding_claim(entry)
          {:ok, binding, Contract.digest(binding)}
        else
          false -> {:error, :unauthorized}
          {:error, _} = error -> error
          _ -> {:error, :unauthorized}
        end

      %{global_fenced: true} ->
        {:error, :unauthorized}

      %{blocked: true} ->
        {:error, :access_storage_unavailable}

      %{negotiated: false} ->
        {:error, :not_connected}

      _ ->
        {:error, :access_owner_unavailable}
    end
  end

  def validate(fingerprint, server \\ Access) do
    with {:ok, _, current} <- current(server),
         true <- fingerprint == current do
      :ok
    else
      false -> {:error, :authority_changed}
      error -> error
    end
  end

  # Access owns the final admission guard and serializes inventory changes while
  # the immutable event is committed to the spool. The fingerprint selects no grant.
  def admit(fingerprint, fun, server \\ Access) when is_function(fun, 0) do
    with :ok <- Backplane.HostAgent.MemoryProxy.authorize_command(),
         :ok <- validate(fingerprint, server),
         {:ok, target, ticket} <- Access.begin_request(:default, :source, server) do
      result =
        Access.run_local(
          target,
          :source,
          fn current ->
            if Enum.all?(@extensions, &(&1 in current.extensions)) and
                 Contract.digest(binding_claim(current)) == fingerprint,
               do: fun.(),
               else: {:error, :authority_changed}
          end,
          server
        )

      case result do
        {:ok, _, _} ->
          reply = %{
            "access" => Access.claim(target),
            "partition" => target.partition,
            "result" => %{"durable" => true}
          }

          with {:ok, permitted, _} <- Access.finish_request(ticket, {:ok, reply}, server),
               do: Access.run_local(permitted, :source, fn _ -> result end, server)

        error ->
          _ = Access.finish_request(ticket, error, server)
          error
      end
    end
  end

  defp extension_check(extensions),
    do:
      if(Enum.all?(@extensions, &(&1 in extensions)),
        do: :ok,
        else: {:error, :unsupported_capability}
      )

  defp binding_claim(entry),
    do: %{
      "access_id" => entry.access_id,
      "authority_version" => entry.authority_version,
      "partition" => stringify(entry.partition)
    }

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
