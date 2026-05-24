defmodule Backplane.Skills.Source do
  @moduledoc """
  Behaviour for skill sources (git, local, database).
  """

  @type skill_entry :: %{
          required(:id) => String.t(),
          required(:slug) => String.t(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:tags) => [String.t()],
          required(:content) => String.t(),
          required(:content_hash) => String.t() | nil,
          required(:version) => String.t() | nil,
          required(:license) => String.t() | nil,
          required(:homepage) => String.t() | nil,
          required(:author) => String.t() | nil,
          required(:meta) => map(),
          required(:archive_ref) => String.t() | nil,
          required(:size_bytes) => non_neg_integer() | nil,
          required(:file_count) => non_neg_integer() | nil,
          required(:source_kind) => String.t() | nil,
          required(:source_uri) => String.t() | nil,
          required(:source_rev) => String.t() | nil
        }

  @callback list() :: {:ok, [skill_entry]} | {:error, term()}
  @callback fetch(skill_id :: String.t()) :: {:ok, skill_entry} | {:error, term()}
end
