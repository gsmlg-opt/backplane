defmodule Backplane.Proxy.McpUpstream do
  @moduledoc "Ecto schema for the mcp_upstreams table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "mcp_upstreams" do
    field :name, :string
    field :prefix, :string
    field :transport, :string
    field :url, :string
    field :command, :string
    field :args, {:array, :string}, default: []
    field :credential, :string
    field :timeout_ms, :integer, default: 30000
    field :refresh_interval_ms, :integer, default: 300000
    field :enabled, :boolean, default: true

    timestamps()
  end

  @required ~w(name prefix transport)a
  @optional ~w(url command args credential timeout_ms refresh_interval_ms enabled)a

  def changeset(upstream, attrs) do
    upstream
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:transport, ~w(http stdio))
    |> validate_transport_fields()
    |> unique_constraint(:name)
    |> unique_constraint(:prefix)
  end

  defp validate_transport_fields(changeset) do
    case get_field(changeset, :transport) do
      "http" -> validate_required(changeset, [:url])
      "stdio" -> validate_required(changeset, [:command])
      _ -> changeset
    end
  end
end
