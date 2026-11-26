defmodule Mix.Tasks.Backplane.Skills.Publish do
  use Mix.Task
  alias Backplane.Skills
  alias Backplane.Skills.{SkillSources, Sources.Database}

  @shortdoc "Preview or publish skills for one configured source"
  @moduledoc """
  Preview pending database skills with `mix backplane.skills.publish --database`, or
  preview the selected skills of one GitHub source with `--source UUID`.
  Pass `--apply` to publish the listed records. Disabled skills keep their state.
  """
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, positional} =
      OptionParser.parse!(args, strict: [database: :boolean, source: :string, apply: :boolean])

    case {positional, opts[:database], opts[:source]} do
      {[], true, nil} -> database(opts[:apply])
      {[], nil, uuid} when is_binary(uuid) -> github(uuid, opts[:apply])
      _ -> Mix.raise("Choose exactly one of --database or --source UUID")
    end
  end

  defp database(apply?) do
    results =
      Skills.list_all(source_kind: "database")
      |> Enum.reject(&(&1.publication_status == "ready"))
      |> Enum.map(fn skill ->
        if apply? do
          case Database.update(skill.id, %{}) do
            {:ok, %{publication_status: "ready"} = saved} -> {skill.id, saved.current_revision}
            _ -> {skill.id, :failed}
          end
        else
          {skill.id, :preview}
        end
      end)

    report(results)
  end

  defp github(id, apply?) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, source} <- SkillSources.get(id),
         {:ok, entries} <- SkillSources.preview_sync(source) do
      if apply? do
        {:ok, result} = SkillSources.sync_skills(source, entries, source.sync_tags || [])
        success = Enum.map(result.published, &{&1.id, &1.revision})
        failed = Enum.map(result.errors, fn {slug, _} -> {slug, :failed} end)
        report(success ++ failed)
      else
        report(
          Enum.map(entries, fn entry ->
            {entry.slug, if(entry[:error], do: :failed, else: :preview)}
          end)
        )
      end
    else
      _ -> Mix.raise("Cannot preview configured GitHub source")
    end
  end

  defp report(rows) do
    Enum.each(rows, fn {id, status} -> Mix.shell().info("#{id}  #{status}") end)

    if Enum.any?(rows, fn {_, status} -> status == :failed end),
      do: Mix.raise("Some skills could not be published")
  end
end
