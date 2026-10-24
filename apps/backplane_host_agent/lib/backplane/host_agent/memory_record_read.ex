defmodule Backplane.HostAgent.MemoryRecordRead do
  @moduledoc false

  alias Backplane.HostAgent.{MemoryFacade, MemoryProxy}
  alias Backplane.HostAgent.Memory.Access
  alias Backplane.MemoryReadRequest

  @max_reply_bytes 524_288
  @canonical_errors ~w(not_found unauthorized invalid_arguments unsupported_filter payload_too_large unsupported_operation canonical_unavailable)

  def call(args, context) do
    with :ok <- authorize(args),
         {:ok, args} <- MemoryReadRequest.validate("get", args) do
      case selector(args, context) do
        :private -> private_read(args, context)
        selector -> selected_read(selector, args, context)
      end
    end
    |> normalize_error()
  end

  defp authorize(%{"memory_access_id" => _}), do: MemoryProxy.authorize_command()
  defp authorize(_), do: MemoryProxy.authorize_private()

  defp selector(%{"memory_access_id" => id}, _context), do: {:access_id, id}

  defp selector(_args, context) do
    case Access.status(access_server(context)) do
      %{negotiated: true} -> :default
      _ -> :private
    end
  end

  defp private_read(args, context) do
    with {:ok, reply} <- remote_read(args, remote_opts(context), context),
         :ok <- MemoryProxy.authorize_private() do
      canonical_result(reply, args)
    end
  end

  defp selected_read(selector, args, context) do
    server = access_server(context)

    with {:ok, target, ticket} <- Access.begin_request(selector, :read, server) do
      opts =
        remote_opts(context)
        |> Keyword.put(:access, Access.claim(target))
        |> Keyword.put(:connection_generation, target.connection_generation)

      reply = remote_read(Map.delete(args, "memory_access_id"), opts, context)

      with {:ok, permitted, canonical} <- Access.finish_request(ticket, reply, server) do
        Access.run_local(permitted, :read, fn _ -> canonical_result(canonical, args) end, server)
      end
    end
  end

  defp remote_read(args, opts, context) do
    adapter = Map.get(context, :remote_adapter, MemoryProxy)

    case adapter.call("get", args, opts) do
      {:ok, reply} when is_map(reply) ->
        if byte_size(Jason.encode!(%{"ok" => true, "result" => reply})) <= @max_reply_bytes,
          do: {:ok, reply},
          else: {:error, :payload_too_large}

      {:error, _} = error ->
        error

      other ->
        {:error, {:canonical_protocol_error, {:unexpected_reply, other}}}
    end
  end

  defp canonical_result(
         %{"record" => %{"id" => id, "canonical_id" => canonical_id}} = result,
         args
       )
       when id == canonical_id do
    if id == args["id"],
      do: {:ok, result},
      else: {:error, {:canonical_protocol_error, :record_mismatch}}
  end

  defp canonical_result(_result, _args),
    do: {:error, {:canonical_protocol_error, :invalid_record}}

  defp normalize_error({:error, reason}) do
    cond do
      MemoryFacade.transport_error?(reason) -> {:error, :canonical_unavailable}
      unsupported_operation?(reason) -> {:error, :unsupported_operation}
      reason in @canonical_errors -> {:error, String.to_existing_atom(reason)}
      is_map(reason) -> normalize_structured_error(reason)
      true -> {:error, reason}
    end
  end

  defp normalize_error(result), do: result

  defp normalize_structured_error(%{"code" => code}) when code in @canonical_errors,
    do: {:error, String.to_existing_atom(code)}

  defp normalize_structured_error(error), do: {:error, error}

  defp unsupported_operation?({:unknown_method, "get"}), do: true
  defp unsupported_operation?({:unknown_tool, "memory::get"}), do: true
  defp unsupported_operation?(%{"code" => "unknown_method", "method" => "get"}), do: true
  defp unsupported_operation?(%{"code" => "unknown_tool", "tool" => "memory::get"}), do: true
  defp unsupported_operation?(%{"code" => "unsupported_operation"}), do: true
  defp unsupported_operation?("unknown memory method: get"), do: true
  defp unsupported_operation?(_), do: false

  defp access_server(context), do: Map.get(context, :access_server, Access)

  defp remote_opts(context) do
    [agent_id: Map.fetch!(context, :agent_id), inject_agent_id: false]
    |> then(fn opts ->
      case Map.fetch(context, :timeout) do
        {:ok, timeout} -> Keyword.put(opts, :timeout, timeout)
        :error -> opts
      end
    end)
  end
end
