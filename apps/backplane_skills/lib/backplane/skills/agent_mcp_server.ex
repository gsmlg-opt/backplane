defmodule Backplane.Skills.AgentMcpServer do
  @moduledoc """
  Ecto schema for MCP server definitions that host agents should run.

  Supports both HTTP and stdio transports. When `host_id` is nil,
  the config applies to all connected agents.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_mcp_servers" do
    field(:host_id, :binary_id)
    field(:name, :string)
    field(:prefix, :string)
    field(:transport, :string, default: "http")
    field(:url, :string)
    field(:command, :string)
    field(:args, {:array, :string}, default: [])
    field(:env, :map, default: %{})
    field(:enabled, :boolean, default: true)

    timestamps()
  end

  @required_fields ~w(name prefix transport)a
  @optional_fields ~w(host_id url command args env enabled)a

  @doc "Changeset for creating or updating an agent MCP server config."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(server, attrs) do
    server
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:transport, ~w(http stdio))
    |> validate_transport_fields()
    |> unique_constraint([:host_id, :prefix], name: :agent_mcp_servers_host_id_prefix_idx)
  end

  defp validate_transport_fields(changeset) do
    case get_field(changeset, :transport) do
      "http" -> validate_required(changeset, [:url])
      "stdio" -> validate_required(changeset, [:command])
      _ -> changeset
    end
  end
end
