defmodule Backplane.Skills.RegistryTest do
  use Backplane.DataCase, async: false

  alias Backplane.Repo
  alias Backplane.Skills.{Registry, Skill}

  setup do
    # Clear ETS
    if :ets.whereis(:backplane_skills) != :undefined do
      :ets.delete_all_objects(:backplane_skills)
    end

    # Insert test data into PG
    insert_skill("reg/s1", "Elixir Patterns", "elixir patterns", "db")
    insert_skill("reg/s2", "OTP Guide", "otp supervision", "git:myskills")
    insert_skill("reg/s3", "React Tips", "react frontend", "local:web")

    # Refresh ETS from PG
    Registry.refresh()

    :ok
  end

  describe "list/1" do
    test "returns all skills from ETS" do
      skills = Registry.list()
      ids = Enum.map(skills, & &1.id)
      assert "reg/s1" in ids
      assert "reg/s2" in ids
      assert "reg/s3" in ids
    end

    test "filters by source when option provided" do
      skills = Registry.list(source: "git")
      ids = Enum.map(skills, & &1.id)
      assert "reg/s2" in ids
      refute "reg/s1" in ids
    end
  end

  describe "search/2" do
    test "searches by keyword in name and description" do
      results = Registry.search("elixir")
      ids = Enum.map(results, & &1.id)
      assert "reg/s1" in ids
    end

    test "respects limit option" do
      results = Registry.search("e", limit: 1)
      assert length(results) <= 1
    end
  end

  describe "fetch/1" do
    test "returns skill by ID from ETS" do
      {:ok, skill} = Registry.fetch("reg/s1")
      assert skill.name == "Elixir Patterns"
    end

    test "returns :not_found for missing" do
      assert {:error, :not_found} = Registry.fetch("nonexistent")
    end
  end

  describe "count/0" do
    test "returns total skill count" do
      assert Registry.count() >= 3
    end
  end

  describe "refresh/0" do
    test "reloads ETS from database" do
      # Add a new skill to PG
      insert_skill("reg/new", "New Skill", "brand new", "db")

      # ETS shouldn't have it yet
      assert {:error, :not_found} = Registry.fetch("reg/new")

      # Refresh
      Registry.refresh()

      # Now it should be there
      {:ok, skill} = Registry.fetch("reg/new")
      assert skill.name == "New Skill"
    end
  end

  defp insert_skill(id, name, description, source) do
    content = "# #{name}"
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %Skill{}
    |> Skill.changeset(%{
      id: id,
      name: name,
      description: description,
      content: content,
      content_hash: hash,
      source: source,
      enabled: true
    })
    |> Repo.insert!()
  end
end
