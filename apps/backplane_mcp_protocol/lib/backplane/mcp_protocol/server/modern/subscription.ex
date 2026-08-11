defmodule Backplane.McpProtocol.Server.Modern.Subscription do
  @moduledoc """
  Immutable data and filtering helpers for one modern MCP subscription.

  Subscription ownership and subscriber monitoring live in the hub; this
  module only validates filters and builds protocol envelopes.
  """

  alias Backplane.McpProtocol.MCP.Error

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  @enforce_keys [:ref, :subscriber, :request_id, :notifications]
  defstruct [:ref, :subscriber, :request_id, :server_info, notifications: %{}, request_meta: %{}]

  @type t :: %__MODULE__{
          ref: reference(),
          subscriber: pid(),
          request_id: String.t() | integer(),
          notifications: map(),
          request_meta: map(),
          server_info: map() | nil
        }

  @spec new(pid(), map()) :: {:ok, t()} | {:error, Error.t()}
  def new(subscriber, request_context) when is_pid(subscriber) and is_map(request_context) do
    request = Map.get(request_context, :request, %{})
    params = Map.get(request, "params", %{})
    capabilities = Map.get(request_context, :server_capabilities, %{})

    with true <- valid_request_id?(request["id"]),
         true <- is_map(params),
         {:ok, requested} <- validate_filter(params),
         {:ok, honored} <- honor_filter(requested, capabilities) do
      {:ok,
       %__MODULE__{
         ref: make_ref(),
         subscriber: subscriber,
         request_id: request["id"],
         notifications: honored,
         request_meta: normalize_meta(params["_meta"]),
         server_info: safe_server_info(Map.get(request_context, :server_info))
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid_params("notifications", "must be an object")
    end
  end

  def new(_subscriber, _request_context), do: invalid_params("notifications", "must be an object")

  @spec acknowledged(t()) :: map()
  def acknowledged(%__MODULE__{} = subscription) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{
        "notifications" => subscription.notifications,
        "_meta" => stamp_meta(subscription.request_meta, subscription.request_id)
      }
    }
  end

  @spec complete(t()) :: map()
  def complete(%__MODULE__{} = subscription) do
    meta = stamp_meta(subscription.request_meta, subscription.request_id)

    meta =
      if is_map(subscription.server_info) do
        Map.put(meta, @server_info_key, subscription.server_info)
      else
        meta
      end

    %{
      "jsonrpc" => "2.0",
      "id" => subscription.request_id,
      "result" => %{"resultType" => "complete", "_meta" => meta}
    }
  end

  @spec deliver(t(), map()) :: {:ok, map()} | :ignore
  def deliver(%__MODULE__{} = subscription, notification) when is_map(notification) do
    if matches?(subscription, notification) do
      {:ok, stamp_notification(notification, subscription.request_id)}
    else
      :ignore
    end
  end

  def deliver(%__MODULE__{}, _notification), do: :ignore

  defp validate_filter(params) do
    case Map.fetch(params, "notifications") do
      {:ok, notifications} when is_map(notifications) -> validate_known_fields(notifications)
      _missing_or_invalid -> invalid_params("notifications", "must be an object")
    end
  end

  defp validate_known_fields(notifications) do
    validators = [
      {"toolsListChanged", &is_boolean/1},
      {"promptsListChanged", &is_boolean/1},
      {"resourcesListChanged", &is_boolean/1},
      {"resourceSubscriptions", &string_list?/1}
    ]

    Enum.reduce_while(validators, {:ok, notifications}, fn {field, validator}, {:ok, value} ->
      case Map.fetch(value, field) do
        :error ->
          {:cont, {:ok, value}}

        {:ok, field_value} ->
          if validator.(field_value) do
            {:cont, {:ok, value}}
          else
            {:halt, invalid_params("notifications.#{field}", "has the wrong type")}
          end
      end
    end)
  end

  defp honor_filter(requested, capabilities) when is_map(capabilities) do
    honored =
      %{}
      |> maybe_honor_flag(requested, "toolsListChanged", capability_enabled?(capabilities, "tools", "listChanged"))
      |> maybe_honor_flag(
        requested,
        "promptsListChanged",
        capability_enabled?(capabilities, "prompts", "listChanged")
      )
      |> maybe_honor_flag(
        requested,
        "resourcesListChanged",
        capability_enabled?(capabilities, "resources", "listChanged")
      )
      |> maybe_honor_resources(requested, capability_enabled?(capabilities, "resources", "subscribe"))

    {:ok, honored}
  end

  defp honor_filter(_requested, _capabilities), do: invalid_params("notifications", "cannot be honored")

  defp maybe_honor_flag(honored, requested, field, true) do
    if requested[field] == true, do: Map.put(honored, field, true), else: honored
  end

  defp maybe_honor_flag(honored, _requested, _field, _unsupported), do: honored

  defp maybe_honor_resources(honored, requested, true) do
    case requested["resourceSubscriptions"] do
      [_ | _] = uris -> Map.put(honored, "resourceSubscriptions", uris)
      _absent_or_empty -> honored
    end
  end

  defp maybe_honor_resources(honored, _requested, _unsupported), do: honored

  defp capability_enabled?(capabilities, capability, feature) do
    capability_config = fetch_string_or_atom(capabilities, capability)

    is_map(capability_config) and
      fetch_feature(capability_config, feature) == true
  end

  defp fetch_string_or_atom(map, "tools"), do: Map.get(map, "tools", Map.get(map, :tools))
  defp fetch_string_or_atom(map, "prompts"), do: Map.get(map, "prompts", Map.get(map, :prompts))
  defp fetch_string_or_atom(map, "resources"), do: Map.get(map, "resources", Map.get(map, :resources))

  defp fetch_feature(map, "listChanged") do
    Map.get(map, "listChanged", Map.get(map, :listChanged, Map.get(map, :list_changed)))
  end

  defp fetch_feature(map, "subscribe") do
    Map.get(map, "subscribe", Map.get(map, :subscribe))
  end

  defp matches?(subscription, %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"} = notification) do
    valid_notification?(notification) and subscription.notifications["toolsListChanged"] == true
  end

  defp matches?(subscription, %{"jsonrpc" => "2.0", "method" => "notifications/prompts/list_changed"} = notification) do
    valid_notification?(notification) and subscription.notifications["promptsListChanged"] == true
  end

  defp matches?(subscription, %{"jsonrpc" => "2.0", "method" => "notifications/resources/list_changed"} = notification) do
    valid_notification?(notification) and subscription.notifications["resourcesListChanged"] == true
  end

  defp matches?(
         subscription,
         %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated", "params" => %{"uri" => uri}} = notification
       )
       when is_binary(uri) do
    valid_notification?(notification) and uri in Map.get(subscription.notifications, "resourceSubscriptions", [])
  end

  defp matches?(_subscription, _notification), do: false

  defp valid_notification?(notification) do
    (not Map.has_key?(notification, "params") or is_map(notification["params"])) and
      not Map.has_key?(notification, "id") and
      not Map.has_key?(notification, "result") and
      not Map.has_key?(notification, "error")
  end

  defp stamp_notification(notification, request_id) do
    Map.update(notification, "params", %{"_meta" => stamp_meta(nil, request_id)}, fn params ->
      Map.put(params, "_meta", stamp_meta(params["_meta"], request_id))
    end)
  end

  defp stamp_meta(meta, request_id) do
    meta
    |> normalize_meta()
    |> Map.delete(:"io.modelcontextprotocol/subscriptionId")
    |> Map.put(@subscription_id_key, request_id)
  end

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_meta), do: %{}

  defp safe_server_info(info) when is_map(info) do
    _encoded = JSON.encode!(info)
    info
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp safe_server_info(_info), do: nil

  defp valid_request_id?(id), do: is_binary(id) or is_integer(id)
  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp string_list?(_values), do: false

  defp invalid_params(field, message) do
    {:error, Error.protocol(:invalid_params, %{field: field, message: message})}
  end
end
