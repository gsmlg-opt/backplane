defmodule Backplane.Memory.GeneratedSkills do
  @moduledoc "Reconciles Memory's generated reference skills into the existing Skill Hub."

  use GenServer

  require Logger

  alias Backplane.Memory.Service
  alias Backplane.Repo
  alias Backplane.Settings
  alias Backplane.Skills.{Registry, Skill}

  @visibility_settings ~w(services.memory.enabled memory.tools memory.pipeline.enabled memory.replay_enabled memory.replay_import_enabled)

  @skills [
    %{
      id: "generated/memory-lessons",
      slug: "lessons",
      name: "Lessons",
      description: "Recall and govern evidence-backed procedural lessons",
      tags: ["memory", "lessons"],
      path: "/lessons",
      source_uri: "backplane://memory/skills/lessons",
      tools:
        ~w(memory::lesson_save memory::lesson_recall memory::lesson_strengthen memory::lesson_promote memory::lesson_archive),
      introduction:
        "Use Backplane's evidence-backed procedural lesson workflow. Recall project-relevant lessons before acting; save durable rules only with their project/context; strengthen only from an explicit confirmation, verified application, or independent evidence. Promotion and lifecycle changes require the corresponding governed tool and an auditable reason."
    },
    %{
      id: "generated/memory-activity",
      slug: "activity",
      name: "Activity",
      description: "Inspect durable activity and replay exact-partition sessions",
      tags: ["memory", "activity", "replay"],
      path: "/activity",
      source_uri: "backplane://memory/skills/activity",
      tools:
        ~w(memory::activity_summary memory::replay_sessions memory::replay_load memory::replay_import),
      introduction:
        "Use Backplane's exact-partition activity and replay workflow. Start with the activity summary, list bounded replay sessions, and load replay events page by page. Import requests never carry filesystem paths or transcript content; they only dispatch to a separately configured host-local importer."
    },
    %{
      id: "generated/memory-recap",
      slug: "recap",
      name: "Recap",
      description: "Recap bounded activity, replay, and Recall Inspector evidence",
      tags: ["memory", "recap", "replay"],
      path: "/recap",
      source_uri: "backplane://memory/skills/recap",
      tools:
        ~w(memory::activity_summary memory::replay_sessions memory::replay_load memory::recall_explain),
      introduction:
        "Use Backplane's bounded recap workflow. Summarize activity first, inspect only the relevant replay page, and use recall explanations when the provenance and scoring of a particular recall run matter. Never infer data outside the authenticated partition."
    },
    %{
      id: "generated/memory-handoff",
      slug: "handoff",
      name: "Handoff",
      description: "Prepare an exact-partition session handoff from durable evidence",
      tags: ["memory", "handoff", "sessions"],
      path: "/handoff",
      source_uri: "backplane://memory/skills/handoff",
      tools: ~w(memory::sessions memory::timeline memory::frontier memory::lesson_recall),
      introduction:
        "Use Backplane's exact-partition handoff workflow. Select the session, inspect its bounded timeline and open action frontier, and include only active evidence-backed lessons relevant to the work being handed over."
    }
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = Settings.subscribe()
    {:ok, nil}
  end

  @impl true
  def handle_info({:setting_changed, key, _value}, state) when key in @visibility_settings do
    reconcile_safely()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec reconcile() :: :ok | {:error, term()}
  def reconcile do
    result =
      if Service.enabled?() do
        visible_tools = Map.new(Service.tools(), &{&1.name, &1})
        Enum.reduce_while(@skills, :ok, &reconcile_skill(&1, &2, visible_tools))
      else
        Enum.reduce_while(@skills, :ok, &disable_skill/2)
      end

    with :ok <- result do
      Registry.refresh()
    end
  end

  defp reconcile_safely do
    case reconcile() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Memory generated skill reconcile failed", reason: inspect(reason))
    end
  rescue
    exception ->
      Logger.warning("Memory generated skill reconcile failed",
        reason: Exception.message(exception)
      )
  end

  defp reconcile_skill(spec, :ok, visible_tools) do
    tools =
      spec.tools
      |> Enum.flat_map(&(Map.take(visible_tools, [&1]) |> Map.values()))
      |> Enum.sort_by(& &1.name)

    case upsert(spec, tools) do
      {:ok, _skill} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp disable_skill(spec, :ok) do
    case Repo.get(Skill, spec.id) do
      nil ->
        {:cont, :ok}

      %Skill{} = skill ->
        case skill |> Ecto.Changeset.change(enabled: false) |> Repo.update() do
          {:ok, _skill} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end
  end

  defp upsert(spec, tools) do
    attrs = attributes(spec, tools)

    case Repo.get_by(Skill, slug: spec.slug) do
      nil ->
        %Skill{id: spec.id} |> Skill.changeset(attrs) |> Repo.insert()

      %Skill{id: id} = skill when id == spec.id ->
        skill |> Skill.changeset(attrs) |> Repo.update()

      %Skill{} ->
        {:error, :reserved_slug_conflict}
    end
  end

  defp attributes(spec, tools) do
    tool_schemas = Map.new(tools, &{&1.name, &1.input_schema})
    content = content(spec, tools)

    %{
      id: spec.id,
      slug: spec.slug,
      name: spec.name,
      description: spec.description,
      category: "memory",
      tags: spec.tags,
      version: "1.0.0",
      content: content,
      content_hash: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      enabled: true,
      source_kind: "generated",
      source_uri: spec.source_uri,
      meta: %{
        "path" => spec.path,
        "generated_by" => Atom.to_string(__MODULE__),
        "tools" => Enum.map(tools, & &1.name),
        "tool_schemas" => tool_schemas
      }
    }
  end

  defp content(spec, tools) do
    contracts =
      Enum.map_join(tools, "\n", fn tool ->
        "- `#{tool.name}` — #{tool.description}\n  Input: `#{Jason.encode!(tool.input_schema)}`"
      end)

    """
    # #{spec.name}

    #{spec.introduction}

    ## Live tools

    #{contracts}
    """
  end
end
