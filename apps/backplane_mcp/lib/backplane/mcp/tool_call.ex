defmodule Backplane.MCP.ToolCall do
  @moduledoc """
  Logical schema for MCP tool-call child access records.

  Maps to the physical `mcp_tool_calls` table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "mcp_tool_calls" do
    field(:event_id, :string)
    field(:mcp_request_id, :string)
    field(:trace_id, :string)
    field(:span_id, :string)
    field(:parent_span_id, :string)

    field(:tool_name, :string)
    field(:tool_namespace, :string)
    field(:original_tool_name, :string)
    field(:execution_kind, :string)

    field(:upstream_name, :string)
    field(:upstream_prefix, :string)
    field(:upstream_transport, :string)
    field(:upstream_protocol_version, :string)

    field(:arguments_hash, :string)
    field(:cache_status, :string)
    field(:timeout_ms, :integer)
    field(:attempt_count, :integer)
    field(:duration_ms, :integer)

    field(:outcome, :string)
    field(:error_kind, :string)
    field(:error_code, :string)
    field(:error_message, :string)

    field(:metadata, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @persist_fields ~w(
    event_id mcp_request_id trace_id span_id parent_span_id
    tool_name tool_namespace original_tool_name execution_kind
    upstream_name upstream_prefix upstream_transport upstream_protocol_version
    arguments_hash cache_status timeout_ms attempt_count duration_ms
    outcome error_kind error_code error_message metadata
  )a

  @doc "Changeset for inserting a tool-call access record."
  def insert_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @persist_fields)
    |> validate_required([:event_id, :tool_name, :outcome])
    |> unique_constraint(:event_id)
  end
end
