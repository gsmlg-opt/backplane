defmodule Backplane.Repo.Migrations.AddMemoryScopeToSkillHosts do
  use Ecto.Migration

  def change do
    alter table(:skill_hosts), do: add(:memory_scope, :text, null: false, default: "proj_local")

    create constraint(:skill_hosts, :skill_hosts_memory_scope_nonempty,
             check: "btrim(memory_scope) <> ''"
           )
  end
end
