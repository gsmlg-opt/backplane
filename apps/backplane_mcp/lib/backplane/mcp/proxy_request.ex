defmodule Backplane.MCP.ProxyRequest do
  @moduledoc """
  Logical schema for MCP root proxy access records.

  Maps to the physical `mcp_proxy_requests` table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "mcp_proxy_requests" do
    field(:event_id, :string)
    field(:request_id, :string)
    field(:trace_id, :string)

    field(:operation, :string)
    field(:rpc_id, :string)
    field(:rpc_method, :string)
    field(:protocol_version, :string)
    field(:era, :string)
    field(:transport, :string)
    field(:session_id, :string)

    field(:client_id, :binary_id)
    field(:client_name, :string)
    field(:client_version, :string)
    field(:auth_kind, :string)
    field(:remote_ip, :string)

    field(:http_method, :string)
    field(:path, :string)
    field(:http_status, :integer)
    field(:jsonrpc_error_code, :integer)

    field(:request_bytes, :integer)
    field(:response_bytes, :integer)
    field(:duration_ms, :integer)

    field(:outcome, :string)
    field(:idempotency_status, :string)
    field(:error_kind, :string)
    field(:error_code, :string)
    field(:error_message, :string)

    field(:metadata, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @persist_fields ~w(
    event_id request_id trace_id operation rpc_id rpc_method protocol_version era
    transport session_id client_id client_name client_version auth_kind remote_ip
    http_method path http_status jsonrpc_error_code request_bytes response_bytes
    duration_ms outcome idempotency_status error_kind error_code error_message metadata
  )a

  @doc "Changeset for inserting a proxy access record."
  def insert_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @persist_fields)
    |> validate_required([:event_id, :operation, :outcome])
    |> unique_constraint(:event_id)
  end
end
