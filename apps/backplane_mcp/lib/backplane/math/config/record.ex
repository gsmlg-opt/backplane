defmodule Backplane.Math.Config.Record do
  @moduledoc "Singleton row storing runtime config for the native Math server."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "mcp_native_math_config" do
    field :enabled, :boolean, default: true
    field :sympy_enabled, :boolean, default: false
    field :sympy_pool_size, :integer, default: 2
    field :sympy_rpc_timeout_ms, :integer, default: 4_000
    field :exla_enabled, :boolean, default: false
    field :timeout_default_ms, :integer, default: 5_000
    field :timeout_per_tool, :map, default: %{}
    field :max_expr_nodes, :integer, default: 10_000
    field :max_expr_depth, :integer, default: 64
    field :max_integer_bits, :integer, default: 4_096
    field :max_matrix_dim, :integer, default: 512
    field :max_factor_bits, :integer, default: 128
    field :decimal_precision, :integer, default: 28
    field :units_system, :string, default: "si"

    timestamps(type: :utc_datetime_usec, inserted_at: false)
  end

  @all_fields ~w(
    enabled sympy_enabled sympy_pool_size sympy_rpc_timeout_ms exla_enabled
    timeout_default_ms timeout_per_tool max_expr_nodes max_expr_depth
    max_integer_bits max_matrix_dim max_factor_bits decimal_precision
    units_system
  )a

  @units_systems ~w(si imperial both)

  def changeset(record, attrs) do
    record
    |> cast(attrs, @all_fields)
    |> validate_number(:timeout_default_ms, greater_than: 0)
    |> validate_number(:sympy_pool_size, greater_than_or_equal_to: 0)
    |> validate_number(:sympy_rpc_timeout_ms, greater_than: 0)
    |> validate_number(:max_expr_nodes, greater_than: 0)
    |> validate_number(:max_expr_depth, greater_than: 0)
    |> validate_number(:max_integer_bits, greater_than: 0)
    |> validate_number(:max_matrix_dim, greater_than: 0)
    |> validate_number(:max_factor_bits, greater_than: 0)
    |> validate_number(:decimal_precision, greater_than: 0, less_than_or_equal_to: 200)
    |> validate_inclusion(:units_system, @units_systems)
  end

  @doc "Returns a Record struct populated with the defaults the migration sets."
  def defaults, do: %__MODULE__{id: 1}
end
