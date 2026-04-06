defmodule Backplane.Jobs.EmbedSkills do
  @moduledoc """
  Oban worker that embeds skills missing vector embeddings.

  Runs after skill sync completes. Embeds the concatenation of
  name + description + first 500 chars of content.

  Idempotent: skips rows where embedding IS NOT NULL.
  The embedding column is accessed via raw fragments since it's not in the Ecto schema.
  """

  use Oban.Worker,
    queue: :embeddings,
    unique: [fields: [:args], period: 120]

  require Logger

  import Ecto.Query

  alias Backplane.Embeddings
  alias Backplane.Repo
  alias Backplane.Skills.Skill

  @content_prefix_length 500

  @impl true
  def perform(%Oban.Job{}) do
    unless Embeddings.configured?() do
      Logger.debug("Embeddings not configured, skipping embed_skills job")
      :ok
    else
      batch_size = Embeddings.config()[:batch_size] || 32

      skills =
        Skill
        |> where([s], s.enabled == true)
        |> where([s], fragment("? IS NULL", s.embedding))
        |> select([s], %{id: s.id, name: s.name, description: s.description, content: s.content})
        |> Repo.all()

      if skills == [] do
        Logger.debug("No skills to embed")
        :ok
      else
        Logger.info("Embedding #{length(skills)} skills")
        embed_in_batches(skills, batch_size)
      end
    end
  end

  defp embed_in_batches(skills, batch_size) do
    skills
    |> Enum.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      texts = Enum.map(batch, &skill_text/1)

      case Embeddings.embed_batch(texts) do
        {:ok, vectors} ->
          Enum.zip(batch, vectors)
          |> Enum.each(fn {skill, vector} ->
            json_vec = Jason.encode!(vector)

            Repo.query!(
              "UPDATE skills SET embedding = $1::vector WHERE id = $2",
              [json_vec, skill.id]
            )
          end)

        {:error, reason} ->
          Logger.warning("Failed to embed batch of #{length(batch)} skills: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp skill_text(skill) do
    content_prefix = String.slice(skill.content || "", 0, @content_prefix_length)
    "#{skill.name} #{skill.description} #{content_prefix}"
  end
end
