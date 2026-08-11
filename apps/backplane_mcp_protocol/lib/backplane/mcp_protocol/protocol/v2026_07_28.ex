# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule Backplane.McpProtocol.Protocol.V2026_07_28 do
  @moduledoc """
  Independent protocol profile for MCP specification version 2026-07-28.

  This revision is stateless and therefore does not inherit the legacy
  initialization, session, server-request, or Tasks method sets.
  """

  @behaviour Backplane.McpProtocol.Protocol.Behaviour

  alias Backplane.McpProtocol.Protocol.Profile

  @version "2026-07-28"

  @features [
    :authorization,
    :audio_content,
    :basic_messaging,
    :cancellation,
    :completion_capability,
    :custom_headers,
    :elicitation,
    :embedded_resources_in_prompts,
    :embedded_resources_in_tools,
    :json_schema_2020_12,
    :logging,
    :model_preferences,
    :multi_round_trip_requests,
    :progress,
    :progress_messages,
    :prompts,
    :request_metadata,
    :resources,
    :result_caching,
    :result_types,
    :roots,
    :sampling,
    :server_discovery,
    :stateless,
    :structured_content_json_values,
    :structured_tool_results,
    :subscriptions,
    :tool_annotations,
    :tool_output_schemas,
    :tools
  ]

  @request_methods ~w(
    server/discover completion/complete
    prompts/get prompts/list
    resources/list resources/templates/list resources/read
    subscriptions/listen
    tools/call tools/list
  )

  @notification_methods ~w(
    notifications/cancelled notifications/message notifications/progress
    notifications/prompts/list_changed
    notifications/resources/list_changed notifications/resources/updated
    notifications/subscriptions/acknowledged
    notifications/tools/list_changed
  )

  @cacheable_methods ~w(
    server/discover prompts/list resources/list
    resources/templates/list resources/read tools/list
  )

  @named_methods ~w(prompts/get resources/read tools/call)

  @progress_params_schema %{
    "progressToken" => {:required, {:either, {:string, :integer}}},
    "progress" => {:required, {:either, {:float, :integer}}},
    "total" => {:either, {:float, :integer}},
    "message" => :string
  }

  @impl true
  def version, do: @version

  @impl true
  def profile do
    %Profile{
      version: @version,
      era: :modern,
      lifecycle: :per_request,
      request_methods: @request_methods,
      notification_methods: @notification_methods,
      features: @features,
      cacheable_methods: @cacheable_methods,
      named_methods: @named_methods
    }
  end

  @impl true
  def supported_features, do: @features

  @impl true
  def request_methods, do: @request_methods

  @impl true
  def notification_methods, do: @notification_methods

  @impl true
  def progress_params_schema, do: @progress_params_schema

  @impl true
  def request_params_schema(_method), do: :map

  @impl true
  def notification_params_schema(_method), do: :map
end
