defmodule Backplane.Fixtures do
  @moduledoc """
  Factory functions for test data creation.

  Provides functions to build and insert common test entities:
  projects, doc_chunks, skills, and upstream configs.
  """

  alias Backplane.Docs.{DocChunk, Project}
  alias Backplane.Repo
  alias Backplane.Skills.Skill

  @fixtures_dir Path.expand("fixtures", __DIR__)

  # --- Fixture File Helpers ---

  @doc "Read a fixture file from the given subdirectory."
  @spec read_fixture(String.t(), String.t()) :: String.t()
  def read_fixture(subdir, filename) do
    Path.join([@fixtures_dir, subdir, filename])
    |> File.read!()
  end

  @doc "Get the absolute path to a fixture file."
  @spec fixture_path(String.t(), String.t()) :: String.t()
  def fixture_path(subdir, filename) do
    Path.join([@fixtures_dir, subdir, filename])
  end

  # --- Project Factories ---

  @doc "Build a project map (not inserted)."
  @spec build_project(keyword()) :: map()
  def build_project(overrides \\ []) do
    id = Keyword.get(overrides, :id, "test-project-#{unique()}")

    %{
      id: id,
      repo: Keyword.get(overrides, :repo, "https://github.com/test/#{id}.git"),
      ref: Keyword.get(overrides, :ref, "main"),
      description: Keyword.get(overrides, :description, "Test project #{id}")
    }
  end

  @doc "Insert a project into the database."
  @spec insert_project(keyword()) :: Project.t()
  def insert_project(overrides \\ []) do
    attrs = build_project(overrides)
    Repo.insert!(%Project{} |> Project.changeset(attrs))
  end

  # --- DocChunk Factories ---

  @doc "Build a doc chunk map (not inserted)."
  @spec build_doc_chunk(keyword()) :: map()
  def build_doc_chunk(overrides \\ []) do
    content = Keyword.get(overrides, :content, "Test documentation content")

    %{
      project_id: Keyword.get_lazy(overrides, :project_id, fn -> "test-project-#{unique()}" end),
      source_path: Keyword.get(overrides, :source_path, "lib/example.ex"),
      module: Keyword.get(overrides, :module, "Example"),
      function: Keyword.get(overrides, :function),
      chunk_type: Keyword.get(overrides, :chunk_type, "moduledoc"),
      content: content,
      content_hash: Keyword.get(overrides, :content_hash, hash(content)),
      tokens: Keyword.get(overrides, :tokens, estimate_tokens(content))
    }
  end

  @doc "Insert a doc chunk into the database."
  @spec insert_doc_chunk(keyword()) :: DocChunk.t()
  def insert_doc_chunk(overrides \\ []) do
    attrs = build_doc_chunk(overrides)
    Repo.insert!(%DocChunk{} |> DocChunk.changeset(attrs))
  end

  # --- Skill Factories ---

  @doc "Build a skill map (not inserted)."
  @spec build_skill(keyword()) :: map()
  def build_skill(overrides \\ []) do
    name = Keyword.get(overrides, :name, "test-skill-#{unique()}")
    content = Keyword.get(overrides, :content, "# #{name}\n\nSkill content here.")

    %{
      id: Keyword.get(overrides, :id, name),
      name: name,
      description: Keyword.get(overrides, :description, "A test skill"),
      tags: Keyword.get(overrides, :tags, ["test"]),
      tools: Keyword.get(overrides, :tools, []),
      model: Keyword.get(overrides, :model),
      version: Keyword.get(overrides, :version, "1.0.0"),
      content: content,
      content_hash: Keyword.get(overrides, :content_hash, hash(content)),
      source: Keyword.get(overrides, :source, "test"),
      enabled: Keyword.get(overrides, :enabled, true)
    }
  end

  @doc "Insert a skill into the database."
  @spec insert_skill(keyword()) :: Skill.t()
  def insert_skill(overrides \\ []) do
    attrs = build_skill(overrides)
    Repo.insert!(%Skill{} |> Skill.changeset(attrs))
  end

  # --- Upstream Config Factories ---

  @doc "Build an upstream MCP server config map."
  @spec build_upstream_config(keyword()) :: map()
  def build_upstream_config(overrides \\ []) do
    prefix = Keyword.get(overrides, :prefix, "test-#{unique()}")

    %{
      name: Keyword.get(overrides, :name, prefix),
      prefix: prefix,
      transport: Keyword.get(overrides, :transport, "http"),
      url: Keyword.get(overrides, :url, "http://127.0.0.1:4200/mcp"),
      headers: Keyword.get(overrides, :headers, %{})
    }
  end

  # --- Client Factories ---

  @doc "Build a client map (not inserted)."
  @spec build_client(keyword()) :: map()
  def build_client(overrides \\ []) do
    name = Keyword.get(overrides, :name, "test-client-#{unique()}")

    token =
      Keyword.get(
        overrides,
        :token,
        "bp_test_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
      )

    %{
      name: name,
      token_hash: Keyword.get(overrides, :token_hash, Bcrypt.hash_pwd_salt(token)),
      scopes: Keyword.get(overrides, :scopes, ["*"]),
      active: Keyword.get(overrides, :active, true),
      metadata: Keyword.get(overrides, :metadata, %{})
    }
  end

  @doc "Insert a client into the database. Returns {client, plaintext_token}."
  @spec insert_client(keyword()) :: {Backplane.Clients.Client.t(), String.t()}
  def insert_client(overrides \\ []) do
    token =
      Keyword.get(
        overrides,
        :token,
        "bp_test_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
      )

    overrides = Keyword.put(overrides, :token_hash, Bcrypt.hash_pwd_salt(token))
    attrs = build_client(overrides)

    client =
      %Backplane.Clients.Client{}
      |> Backplane.Clients.Client.changeset(attrs)
      |> Repo.insert!()

    {client, token}
  end

  # --- Helpers ---

  defp unique, do: System.unique_integer([:positive])

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp estimate_tokens(content), do: max(div(byte_size(content), 4), 1)
end
