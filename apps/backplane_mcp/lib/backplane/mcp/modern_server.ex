defmodule Backplane.MCP.ModernServer do
  @moduledoc """
  Stateless MCP 2026-07-28 adapter for Backplane's shared application dispatch.
  """

  use Backplane.McpProtocol.Server,
    name: "backplane",
    version: Backplane.MCP.Info.version(),
    capabilities: [:tools, :resources, :prompts, :completion],
    protocol_versions: ["2026-07-28"],
    instructions: "Backplane is an MCP hub. Tools use prefix::name namespaces."

  alias Backplane.MCP.Dispatch
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Server.Component.Schema
  alias Backplane.McpProtocol.Server.Frame

  @protocol_version "2026-07-28"
  @open_auth %{kind: :open, client_id: nil, scopes: ["*"]}
  @auth_fields [:kind, :subject, :client_id, :principal_metadata, :resource, :scopes]
  @auth_kinds [:oauth, :client_token, :legacy, :open]

  @impl true
  def init_request(context, frame) do
    with {:ok, dispatch_context} <- dispatch_context(context.assigns, context.auth),
         tools when is_list(tools) <- Dispatch.visible_tools(dispatch_context) do
      frame = Frame.assign(frame, :dispatch_context, dispatch_context)

      frame = Enum.reduce(tools, frame, &register_tool/2)

      {:ok, frame}
    else
      {:error, kind, message} ->
        {:error, modern_error(kind, message), frame}

      :error ->
        {:error, Error.protocol(:internal_error), frame}
    end
  end

  @impl true
  def handle_request(%{"method" => method} = request, frame) do
    case Dispatch.execute(method, request["params"] || %{}, frame.assigns.dispatch_context) do
      {:ok, result} -> {:reply, result, frame}
      {:error, kind, message} -> {:error, modern_error(kind, message), frame}
    end
  end

  defp register_tool(tool, frame) do
    Frame.register_tool(frame, tool.name,
      title: tool.name,
      description: tool.description,
      input_schema: Schema.raw(tool.input_schema),
      output_schema: raw_optional(tool.output_schema),
      annotations: tool.annotations
    )
  end

  defp dispatch_context(assigns, transport_auth) when is_map(assigns) do
    with {:ok, transport_auth} <- normalize_transport_auth(transport_auth),
         {:ok, assigned_auth} <- fetch_assign(assigns, :resource_auth, &normalize_auth/1),
         {:ok, assigned_scopes} <- fetch_assign(assigns, :tool_scopes, &normalize_scopes/1),
         {:ok, client} <- fetch_assign(assigns, :client, &normalize_client/1),
         {:ok, auth} <- resolve_auth(transport_auth, assigned_auth, assigned_scopes),
         {:ok, scopes} <- resolve_scopes(auth, assigned_scopes) do
      {:ok,
       %{
         protocol_version: @protocol_version,
         scopes: scopes,
         auth: auth,
         client: present_value(client)
       }}
    else
      _invalid -> :error
    end
  end

  defp normalize_transport_auth(nil), do: {:ok, :absent}

  defp normalize_transport_auth(auth) do
    case normalize_auth(auth) do
      {:ok, normalized} -> {:ok, {:present, normalized}}
      :error -> :error
    end
  end

  defp resolve_auth(:absent, :absent, :absent), do: {:ok, @open_auth}
  defp resolve_auth(:absent, :absent, {:present, _scopes}), do: :error
  defp resolve_auth({:present, auth}, :absent, _assigned_scopes), do: {:ok, auth}
  defp resolve_auth(:absent, {:present, auth}, _assigned_scopes), do: {:ok, auth}

  defp resolve_auth({:present, transport_auth}, {:present, assigned_auth}, _assigned_scopes) do
    if same_authority?(transport_auth, assigned_auth), do: {:ok, assigned_auth}, else: :error
  end

  defp resolve_scopes(auth, :absent), do: {:ok, auth.scopes}

  defp resolve_scopes(auth, {:present, scopes}) do
    if Enum.all?(scopes, &Backplane.Clients.scope_matches?(auth.scopes, &1)),
      do: {:ok, scopes},
      else: :error
  end

  defp same_authority?(left, right) do
    Map.delete(left, :scopes) == Map.delete(right, :scopes) and
      MapSet.equal?(MapSet.new(left.scopes), MapSet.new(right.scopes))
  end

  defp fetch_assign(container, key, normalizer) do
    case {Map.fetch(container, key), Map.fetch(container, Atom.to_string(key))} do
      {:error, :error} ->
        {:ok, :absent}

      {{:ok, value}, :error} ->
        normalize_present(value, normalizer)

      {:error, {:ok, value}} ->
        normalize_present(value, normalizer)

      {{:ok, atom_value}, {:ok, string_value}} ->
        with {:ok, normalized_atom} <- normalizer.(atom_value),
             {:ok, normalized_string} <- normalizer.(string_value),
             true <- normalized_atom == normalized_string do
          {:ok, {:present, normalized_atom}}
        else
          _invalid -> :error
        end
    end
  end

  defp normalize_present(value, normalizer) do
    case normalizer.(value) do
      {:ok, normalized} -> {:ok, {:present, normalized}}
      :error -> :error
    end
  end

  defp normalize_auth(auth) when is_map(auth) do
    with {:ok, normalized} <- normalize_auth_fields(auth),
         kind when kind in @auth_kinds <- normalized[:kind],
         scopes when is_list(scopes) <- normalized[:scopes] do
      {:ok, normalized}
    else
      _invalid -> :error
    end
  end

  defp normalize_auth(_auth), do: :error

  defp normalize_auth_fields(auth) do
    Enum.reduce_while(@auth_fields, {:ok, %{}}, fn field, {:ok, normalized} ->
      case fetch_assign(auth, field, &normalize_auth_field(field, &1)) do
        {:ok, :absent} -> {:cont, {:ok, normalized}}
        {:ok, {:present, value}} -> {:cont, {:ok, Map.put(normalized, field, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp normalize_auth_field(:kind, kind) when kind in @auth_kinds, do: {:ok, kind}
  defp normalize_auth_field(:kind, "oauth"), do: {:ok, :oauth}
  defp normalize_auth_field(:kind, "client_token"), do: {:ok, :client_token}
  defp normalize_auth_field(:kind, "legacy"), do: {:ok, :legacy}
  defp normalize_auth_field(:kind, "open"), do: {:ok, :open}

  defp normalize_auth_field(field, value)
       when field in [:subject, :client_id] and (is_binary(value) or is_nil(value)),
       do: {:ok, value}

  defp normalize_auth_field(:principal_metadata, value) when is_map(value), do: {:ok, value}
  defp normalize_auth_field(:resource, resource) when resource in [:mcp, :v1], do: {:ok, resource}
  defp normalize_auth_field(:resource, "mcp"), do: {:ok, :mcp}
  defp normalize_auth_field(:resource, "v1"), do: {:ok, :v1}
  defp normalize_auth_field(:scopes, scopes), do: normalize_scopes(scopes)
  defp normalize_auth_field(_field, _value), do: :error

  defp normalize_scopes(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &is_binary/1), do: {:ok, Enum.uniq(scopes)}, else: :error
  end

  defp normalize_scopes(_scopes), do: :error
  defp normalize_client(client), do: {:ok, client}

  defp present_value(:absent), do: nil
  defp present_value({:present, value}), do: value

  defp raw_optional(nil), do: nil
  defp raw_optional(schema), do: Schema.raw(schema)

  defp modern_error(:method_not_found, _message), do: Error.protocol(:method_not_found)

  defp modern_error(reason, _message) when reason in [:invalid_params, :not_found],
    do: Error.protocol(:invalid_params)

  defp modern_error(:insufficient_scope, _message), do: Error.execution("insufficient_scope")
  defp modern_error(:internal_error, _message), do: Error.protocol(:internal_error)
end
