defmodule Backplane.AgentRuntime.Codex.Hosted do
  @moduledoc """
  Provider-hosted capability negotiation and observation boundary.
  """
  alias Backplane.AgentRuntime.Error

  @max_result_bytes 1_048_576

  @spec declarations(map()) :: {:ok, [map()]} | {:error, Error.t()}
  def declarations(context) when is_map(context) do
    case Map.get(context, :provider_hosted) do
      nil ->
        {:ok, []}

      config when is_map(config) ->
        capabilities = Map.get(config, :capabilities, [])
        adapter = Map.get(config, :adapter)
        adapter_context = Map.get(config, :context, %{})

        with {:ok, negotiated} <- negotiate(adapter, capabilities, adapter_context),
             {:ok, accepted} <- accepted_capabilities(negotiated),
             {:ok, declarations} <- build_declarations(accepted, config) do
          {:ok, declarations}
        end

      _ ->
        {:error, Error.new(:validation, "provider-hosted configuration must be a map")}
    end
  end

  def declarations(_),
    do: {:error, Error.new(:validation, "provider-hosted context must be a map")}

  @spec negotiate(module(), [String.t()], map()) :: {:ok, map()} | {:error, Error.t()}
  def negotiate(adapter, capabilities, context)
      when is_atom(adapter) and is_list(capabilities) and is_map(context) do
    with :ok <- validate_capabilities(capabilities),
         {:ok, result} <-
           call_adapter(
             adapter,
             :negotiate,
             [capabilities, context],
             "provider capability negotiation"
           ) do
      bounded(result)
    end
  end

  @spec invoke(module(), map(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def invoke(adapter, declaration, input, context)
      when is_atom(adapter) and is_map(declaration) and is_map(input) and is_map(context) do
    with :ok <- validate_declaration(declaration),
         {:ok, result} <-
           call_adapter(
             adapter,
             :invoke_hosted,
             [declaration, input, context],
             "provider-hosted invocation"
           ) do
      bounded(result)
    end
  end

  @spec observe(module(), [map()]) :: {:ok, map()} | {:error, Error.t()}
  def observe(adapter, events) when is_atom(adapter) and is_list(events) do
    with :ok <- validate_events(events),
         {:ok, result} <-
           call_adapter(adapter, :observe_hosted, [events], "provider hosted event observation") do
      bounded(result)
    end
  end

  @spec cancel(module(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def cancel(adapter, declaration, context)
      when is_atom(adapter) and is_map(declaration) and is_map(context) do
    with :ok <- validate_declaration(declaration),
         {:ok, result} <-
           call_adapter(
             adapter,
             :cancel_hosted,
             [declaration, context],
             "provider-hosted cancellation"
           ) do
      bounded(result)
    end
  end

  def cancel(_, _, _),
    do: {:error, Error.new(:validation, "hosted cancellation arguments are invalid")}

  defp accepted_capabilities(%{accepted: accepted}) when is_list(accepted), do: {:ok, accepted}

  defp accepted_capabilities(%{"accepted" => accepted}) when is_list(accepted),
    do: {:ok, accepted}

  defp accepted_capabilities(_),
    do:
      {:error, Error.new(:malformed_result, "provider negotiation omitted accepted capabilities")}

  defp build_declarations(accepted, config) do
    if "web_search" in accepted do
      with {:ok, declaration} <- web_search_declaration(Map.get(config, :web_search, %{})) do
        {:ok, [declaration]}
      end
    else
      {:ok, []}
    end
  end

  defp web_search_declaration(config) when is_map(config) do
    mode = Map.get(config, :mode, :disabled)

    with {:ok, access} <- web_search_access(mode),
         :ok <- web_search_context_size(Map.get(config, :search_context_size)),
         :ok <- web_search_content_types(Map.get(config, :search_content_types)) do
      declaration =
        %{type: "web_search"}
        |> Map.merge(access)
        |> maybe_put(:filters, Map.get(config, :filters))
        |> maybe_put(:user_location, Map.get(config, :user_location))
        |> maybe_put(:search_context_size, Map.get(config, :search_context_size))
        |> maybe_put(:search_content_types, Map.get(config, :search_content_types))

      {:ok, declaration}
    end
  end

  defp web_search_declaration(_),
    do: {:error, Error.new(:validation, "provider web search configuration must be a map")}

  defp web_search_access(:cached), do: {:ok, %{external_web_access: false}}

  defp web_search_access(:indexed),
    do: {:ok, %{external_web_access: true, indexed_web_access: true}}

  defp web_search_access(:live), do: {:ok, %{external_web_access: true}}

  defp web_search_access(_),
    do: {:error, Error.new(:validation, "provider web search mode is invalid")}

  defp web_search_context_size(nil), do: :ok
  defp web_search_context_size(value) when value in ["low", "medium", "high"], do: :ok

  defp web_search_context_size(_),
    do: {:error, Error.new(:validation, "provider web search context size is invalid")}

  defp web_search_content_types(nil), do: :ok

  defp web_search_content_types(types) when is_list(types) do
    if types != [] and Enum.all?(types, &(&1 in ["text", "image"])) and Enum.uniq(types) == types,
      do: :ok,
      else: {:error, Error.new(:validation, "provider web search content types are invalid")}
  end

  defp web_search_content_types(_),
    do: {:error, Error.new(:validation, "provider web search content types are invalid")}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp call_adapter(adapter, function, args, operation) do
    if function_exported?(adapter, function, length(args)) do
      case apply(adapter, function, args) do
        {:ok, result} when is_map(result) ->
          {:ok, result}

        {:error, %Error{} = error} ->
          {:error, error}

        other ->
          {:error,
           Error.new(:malformed_result, "#{operation} returned an invalid result",
             details: %{received: other}
           )}
      end
    else
      {:error, Error.new(:unsupported_capability, "#{operation} is unavailable")}
    end
  end

  defp validate_capabilities(capabilities) do
    if Enum.all?(capabilities, &(is_binary(&1) and &1 != "")) and
         Enum.uniq(capabilities) == capabilities,
       do: :ok,
       else: {:error, Error.new(:validation, "provider capabilities must be unique names")}
  end

  defp validate_declaration(declaration) do
    id = Map.get(declaration, :id, Map.get(declaration, "id"))
    name = Map.get(declaration, :name, Map.get(declaration, "name"))

    if (is_binary(id) and id != "") or (is_binary(name) and name != ""),
      do: :ok,
      else: {:error, Error.new(:validation, "hosted declaration requires an id or name")}
  end

  defp validate_events(events) do
    if Enum.all?(events, &is_map/1),
      do: :ok,
      else: {:error, Error.new(:validation, "hosted events must be maps")}
  end

  defp bounded(result) when is_map(result) do
    if :erlang.external_size(result) <= @max_result_bytes,
      do: {:ok, result},
      else:
        {:error,
         Error.new(:budget_exceeded, "provider-hosted result exceeds the configured bound")}
  end
end
