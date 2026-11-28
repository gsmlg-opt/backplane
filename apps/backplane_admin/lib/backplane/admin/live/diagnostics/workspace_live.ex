defmodule Backplane.Admin.Diagnostics.WorkspaceLive do
  use Backplane.Admin, :live_view

  alias Backplane.Diagnostics.{
    Analyses,
    Evidence,
    Issues,
    Outbox,
    Queries,
    RepairTasks,
    Reports,
    Resolutions
  }

  alias Backplane.Skills.AgentManage
  alias Backplane.Settings

  @settings [
    {"Model alias", "diagnostics.analysis.model", :model},
    {"Policy version", "diagnostics.analysis.policy_version", 1..2_147_483_647},
    {"Daily calls", "diagnostics.analysis.daily_calls", 0..5_000},
    {"Daily tokens", "diagnostics.analysis.daily_tokens", 0..50_000_000},
    {"Daily cost in micros", "diagnostics.analysis.daily_cost_micros", 0..10_000_000_000},
    {"Reserved cost per call in micros", "diagnostics.analysis.request_cost_micros",
     0..100_000_000},
    {"Issue cooldown in seconds", "diagnostics.analysis.cooldown_seconds", 0..86_400},
    {"Host diagnostics upload", "diagnostics.host_write.enabled", :boolean}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, evidence: nil, selected_issue: nil)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    action = socket.assigns.live_action

    socket =
      assign(socket, current_path: URI.parse(uri).path, page_title: title(action), evidence: nil)

    {:noreply, load_page(socket, action, params)}
  end

  @impl true
  def handle_event("filter", %{"status" => status, "severity" => severity}, socket) do
    filters =
      Map.reject(%{"status" => status, "severity" => severity}, fn {_key, value} ->
        value == ""
      end)

    {:noreply, push_patch(socket, to: ~p"/system/diagnostics?#{filters}")}
  end

  def handle_event("refresh-health", _, %{assigns: %{live_action: :health}} = socket),
    do: {:noreply, load_page(socket, :health, %{})}

  def handle_event(
        "show-evidence",
        %{"reference" => reference},
        %{assigns: %{report: %{evidence_bundle_id: bundle}}} = socket
      )
      when is_integer(bundle) do
    {:noreply, assign(socket, :evidence, Evidence.fetch(bundle, reference))}
  end

  def handle_event("analyze", _, %{assigns: %{selected_issue: id}} = socket)
      when is_integer(id) do
    case Issues.events(id, limit: 1) do
      [event] ->
        result =
          Backplane.Repo.transact(fn ->
            Issues.enqueue_change(id, event.id, "manual", DateTime.utc_now())
            {:ok, Resolutions.audit!(id, "analysis_requested", "admin", nil)}
          end)

        action_feedback(socket, result, "Analysis requested")

      [] ->
        {:noreply, put_flash(socket, :error, "No available observation for analysis")}
    end
  end

  def handle_event("set-state", %{"status" => status}, %{assigns: %{selected_issue: id}} = socket)
      when is_integer(id) do
    action_feedback(
      socket,
      Resolutions.set_issue_state(id, status, "admin"),
      "Issue state updated"
    )
  end

  def handle_event(
        "move-occurrences",
        %{"destination" => destination, "occurrences" => ids},
        %{assigns: %{selected_issue: id}} = socket
      )
      when is_integer(id) do
    result =
      with {:ok, target} <- Queries.parse_id(destination),
           {:ok, occurrences} <- parse_occurrences(ids) do
        Issues.reassign(id, target, occurrences, "admin")
      end

    action_feedback(socket, result, "Occurrences moved")
  end

  def handle_event(
        "split-occurrences",
        %{"occurrences" => ids},
        %{assigns: %{selected_issue: id}} = socket
      )
      when is_integer(id) do
    result =
      with {:ok, occurrences} <- parse_occurrences(ids),
           do: Issues.split(id, occurrences, "admin")

    case result do
      {:ok, issue} ->
        {:noreply,
         socket
         |> put_flash(:info, "Issue split")
         |> push_patch(to: ~p"/system/diagnostics/issues/#{issue.id}")}

      error ->
        action_feedback(socket, error, nil)
    end
  end

  def handle_event(
        "merge-issue",
        %{"destination" => destination},
        %{assigns: %{selected_issue: id}} = socket
      )
      when is_integer(id) do
    result =
      with {:ok, target} <- Queries.parse_id(destination), do: Issues.merge(id, target, "admin")

    case result do
      {:ok, issue} ->
        {:noreply,
         socket
         |> put_flash(:info, "Issues merged")
         |> push_patch(to: ~p"/system/diagnostics/issues/#{issue.id}")}

      error ->
        action_feedback(socket, error, nil)
    end
  end

  def handle_event(
        "propose-fix",
        %{"resolution" => attrs},
        %{assigns: %{selected_issue: id}} = socket
      )
      when is_integer(id) do
    attrs =
      attrs
      |> Map.update("releases", [], &split_list/1)
      |> Map.update("source_ids", [], &split_list/1)

    action_feedback(socket, Resolutions.propose(id, attrs, "admin"), "Fix scope recorded")
  end

  def handle_event(
        "record-check",
        %{"state" => state, "evidence" => evidence},
        %{assigns: %{resolution: %{id: id}}} = socket
      ) do
    action_feedback(
      socket,
      Resolutions.record_check(id, state, evidence, "admin"),
      "Verification recorded"
    )
  end

  def handle_event(
        "implementation",
        %{"state" => state},
        %{assigns: %{resolution: %{id: id}}} = socket
      ) do
    action_feedback(
      socket,
      Resolutions.implementation(id, state, "admin"),
      "Implementation state updated"
    )
  end

  def handle_event(
        "save-setting",
        %{"key" => key, "value" => value},
        %{assigns: %{live_action: :settings}} = socket
      ) do
    result =
      with {_, ^key, type} <- Enum.find(@settings, fn {_, setting, _} -> setting == key end),
           {:ok, cast} <- setting_value(value, type),
           :ok <- Settings.set(key, cast) do
        Resolutions.audit!(nil, "analysis_setting_updated", "admin", nil)
        :ok
      end

    case result do
      :ok -> {:noreply, socket |> load_page(:settings, %{}) |> put_flash(:info, "Setting saved")}
      _ -> {:noreply, put_flash(socket, :error, "Enter a valid value for the selected setting")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp action_feedback(socket, {:ok, _}, message) do
    id = socket.assigns.selected_issue
    {:noreply, socket |> load_page(:issue, %{"id" => id}) |> put_flash(:info, message)}
  end

  defp action_feedback(socket, _, _),
    do: {:noreply, put_flash(socket, :error, "The diagnostics action could not be saved")}

  defp parse_occurrences(ids) when is_binary(ids) and byte_size(ids) in 1..2_000 do
    case ids |> split_list() |> Enum.map(&Queries.parse_id/1) do
      [_ | _] = parsed ->
        if Enum.all?(parsed, &match?({:ok, _}, &1)),
          do: {:ok, Enum.map(parsed, &elem(&1, 1))},
          else: {:error, :invalid_occurrences}

      [] ->
        {:error, :invalid_occurrences}
    end
  end

  defp parse_occurrences(_), do: {:error, :invalid_occurrences}

  defp load_page(socket, :issues, params) do
    assign(socket,
      result: Queries.search_issues(params),
      filters: Map.take(params, ~w(status severity)),
      selected_issue: nil
    )
  end

  defp load_page(socket, :issue, %{"id" => raw}) do
    with {:ok, id} <- Queries.parse_id(raw), {:ok, issue} <- Queries.get_issue(id) do
      resolution = Resolutions.for_issue(id)

      assign(socket,
        result: {:ok, issue},
        selected_issue: id,
        report: Reports.get(id),
        merged_into: Issues.merged_into(id),
        analysis: Analyses.latest(id),
        repair: RepairTasks.get(id),
        resolution: resolution,
        occurrences: Issues.occurrences(id, limit: 10),
        coverage: if(resolution, do: Resolutions.coverage(resolution.id))
      )
    else
      _ ->
        assign(socket,
          result: {:error, :not_found},
          selected_issue: nil,
          report: nil,
          resolution: nil
        )
    end
  end

  defp load_page(socket, :run, %{"source_id" => source, "run_id" => run}),
    do: assign(socket, :result, Queries.get_run(source, run))

  defp load_page(socket, :health, _) do
    inventory = AgentManage.list_agents(limit: 50)

    assign(socket,
      hosts: inventory.entries,
      truncated: inventory.truncated?,
      queue: Outbox.health()
    )
  end

  defp load_page(socket, :settings, _) do
    settings =
      Enum.map(@settings, fn {label, key, type} -> {label, key, type, Settings.get(key)} end)

    assign(socket, :settings, settings)
  end

  defp load_page(socket, :resolutions, _), do: assign(socket, :resolutions, Resolutions.list())

  defp title(:issues), do: "Diagnostic Issues"
  defp title(:issue), do: "Diagnostic Issue"
  defp title(:run), do: "Run Details"
  defp title(:health), do: "Collection Health"
  defp title(:settings), do: "Analysis Settings"
  defp title(:resolutions), do: "Fix Verification"

  defp split_list(value) when is_binary(value),
    do:
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp split_list(_), do: []

  defp setting_value(value, :model) when is_binary(value) and byte_size(value) <= 128,
    do: {:ok, String.trim(value)}

  defp setting_value("true", :boolean), do: {:ok, true}
  defp setting_value("false", :boolean), do: {:ok, false}

  defp setting_value(value, %Range{} = range) when is_binary(value) and byte_size(value) <= 16 do
    case Integer.parse(value) do
      {number, ""} -> if number in range, do: {:ok, number}, else: :error
      _ -> :error
    end
  end

  defp setting_value(_, _), do: :error

  defp state_label(nil), do: "Unavailable"

  defp state_label(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp host_health(host), do: get_in(host, [:runtime, :diagnostics]) || %{}
end
