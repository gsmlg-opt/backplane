defmodule Backplane.Repo.Migrations.AddMemoryGraphEdgeUniqueIdx do
  use Ecto.Migration

  def change do
    create(
      unique_index(:memory_graph_edges, [:source_id, :target_id, :relation],
        name: :memory_graph_edges_src_tgt_rel_uniq
      )
    )
  end
end
