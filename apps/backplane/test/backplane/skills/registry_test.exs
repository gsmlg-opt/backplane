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
    insert_skill("reg/s1", "Elixir Patterns", "elixir patterns", ["elixir", "otp"],
      source_kind: "database"
    )

    insert_skill("reg/s2", "OTP Guide", "otp supervision", ["elixir", "otp"],
      source_kind: "archive",
      source_uri: "git:myskills",
      source_rev: "abc123",
      version: "2.0.0",
      license: "MIT",
      homepage: "https://example.com/otp",
      archive_ref:
        "sha256/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.tar.gz",
      size_bytes: 128,
      file_count: 3
    )

    insert_skill("reg/s3", "React Tips", "react frontend", ["react", "frontend"],
      source_kind: "database"
    )

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

    test "filters by tags (AND match)" do
      skills = Registry.list(tags: ["elixir"])
      ids = Enum.map(skills, & &1.id)
      assert "reg/s1" in ids
      assert "reg/s2" in ids
      refute "reg/s3" in ids
    end

    test "includes v1 archive metadata in entries" do
      assert {:ok, skill} = Registry.fetch("reg/s2")
      assert skill.slug == "reg-s2"
      assert skill.version == "2.0.0"
      assert skill.license == "MIT"
      assert skill.homepage == "https://example.com/otp"

      assert skill.archive_ref ==
               "sha256/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.tar.gz"

      assert skill.size_bytes == 128
      assert skill.file_count == 3
      assert skill.source_kind == "archive"
      assert skill.source_uri == "git:myskills"
      assert skill.source_rev == "abc123"
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
      insert_skill("reg/new", "New Skill", "brand new", [], source_kind: "database")

      # ETS shouldn't have it yet
      assert {:error, :not_found} = Registry.fetch("reg/new")

      # Refresh
      Registry.refresh()

      # Now it should be there
      {:ok, skill} = Registry.fetch("reg/new")
      assert skill.name == "New Skill"
    end
  end

  defp insert_skill(id, name, description, tags, attrs) do
    content = "# #{name}"
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    base_attrs = %{
      id: id,
      slug: slugify(id),
      name: name,
      description: description,
      tags: tags,
      content: content,
      content_hash: hash,
      enabled: true
    }

    %Skill{}
    |> Skill.changeset(Map.merge(base_attrs, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp slugify(id) do
    id
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
