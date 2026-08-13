defmodule Backplane.Repo.Migrations.PreserveReplayEventKindIdentity do
  use Ecto.Migration

  @moduledoc """
  Compatibility marker for databases that applied the original replay-kind uniqueness fix.

  The final replay uniqueness definition is now created directly by migration 00018 so fresh
  databases are correct without a follow-up alteration. This version remains intentionally
  reversible and schema-neutral to preserve the immutable migration inventory for databases
  where version 00020 is already recorded as applied.
  """

  def up, do: :ok
  def down, do: :ok
end
