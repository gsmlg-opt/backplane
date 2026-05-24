defmodule Backplane.Repo.Migrations.CreateMcpNativeMathConfig do
  use Ecto.Migration

  def change do
    create table(:mcp_native_math_config, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1, null: false

      add :enabled, :boolean, null: false, default: true
      add :sympy_enabled, :boolean, null: false, default: false
      add :sympy_pool_size, :integer, null: false, default: 2
      add :sympy_rpc_timeout_ms, :integer, null: false, default: 4_000
      add :exla_enabled, :boolean, null: false, default: false
      add :timeout_default_ms, :integer, null: false, default: 5_000
      add :timeout_per_tool, :map, null: false, default: %{}
      add :max_expr_nodes, :integer, null: false, default: 10_000
      add :max_expr_depth, :integer, null: false, default: 64
      add :max_integer_bits, :integer, null: false, default: 4_096
      add :max_matrix_dim, :integer, null: false, default: 512
      add :max_factor_bits, :integer, null: false, default: 128
      add :decimal_precision, :integer, null: false, default: 28
      add :units_system, :text, null: false, default: "si"

      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end

    create constraint(:mcp_native_math_config, :singleton, check: "id = 1")
  end
end
