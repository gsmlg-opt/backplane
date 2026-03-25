defmodule Backplane.Skills.Source do
  @moduledoc """
  Behaviour for skill sources (git, local, database).
  """

  @type skill_entry :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          tags: [String.t()],
          tools: [String.t()],
          model: String.t() | nil,
          version: String.t(),
          content: String.t(),
          content_hash: String.t(),
          source: String.t()
        }

  @callback list() :: {:ok, [skill_entry]} | {:error, term()}
  @callback fetch(skill_id :: String.t()) :: {:ok, skill_entry} | {:error, term()}
end
