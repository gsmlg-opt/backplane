defmodule Backplane.Skills.Source do
  @moduledoc """
  Behaviour for skill sources (git, local, database).
  """

  @type skill_entry :: %{
          id: String.t(),
          slug: String.t(),
          name: String.t(),
          description: String.t(),
          tags: [String.t()],
          content: String.t(),
          content_hash: String.t() | nil,
          version: String.t() | nil,
          license: String.t() | nil,
          homepage: String.t() | nil,
          author: String.t() | nil,
          meta: map(),
          archive_ref: String.t() | nil,
          size_bytes: non_neg_integer() | nil,
          file_count: non_neg_integer() | nil,
          source_kind: String.t() | nil,
          source_uri: String.t() | nil,
          source_rev: String.t() | nil
        }

  @callback list() :: {:ok, [skill_entry]} | {:error, term()}
  @callback fetch(skill_id :: String.t()) :: {:ok, skill_entry} | {:error, term()}
end
