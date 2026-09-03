defmodule Backplane.Admin.LogsJobsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.LogsComponents
  import Ecto.Query

  alias Backplane.Memory.Privacy.Filter
  alias Backplane.PubSubBroadcaster
  alias Backplane.Repo

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSubBroadcaster.subscribe(PubSubBroadcaster.skills_sync_topic())
    end

    {:ok,
     assign(socket,
       current_path: "/system/logs/jobs",
       loading: true,
       jobs: [],
       selected_job_id: nil,
       selected_job: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_job_id = parse_job_id(params["job_id"])

    {:noreply,
     socket
     |> assign(selected_job_id: selected_job_id)
     |> load_data()}
  end

  @impl true
  def handle_info({event, _payload}, socket) when event in [:started] do
    {:noreply, load_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="mb-2 text-2xl font-bold">Background Jobs</h1>
      <p class="mb-4 text-sm text-on-surface-variant">Recent Oban job activity.</p>

      <.logs_nav current="/system/logs/jobs" />

      <.dm_card
        :if={@selected_job}
        id={"job-detail-#{@selected_job.id}"}
        variant="bordered"
        padding="sm"
        class="mb-6"
      >
        <h2 class="font-semibold">Job detail</h2>
        <dl class="mt-3 grid gap-2 text-sm sm:grid-cols-2">
          <div><dt class="text-on-surface-variant">Worker</dt><dd class="font-mono text-xs">{@selected_job.worker}</dd></div>
          <div><dt class="text-on-surface-variant">Queue / state</dt><dd>{@selected_job.queue} / {@selected_job.state}</dd></div>
          <div><dt class="text-on-surface-variant">Attempt</dt><dd>{@selected_job.attempt}/{@selected_job.max_attempts}</dd></div>
        </dl>
        <h3 class="mt-4 text-sm font-semibold">Sanitized error</h3>
        <pre class="mt-2 max-h-72 overflow-auto whitespace-pre-wrap break-words text-xs">{@selected_job.error_detail}</pre>
      </.dm_card>

      <div :if={@jobs == []}>
        <.empty_state title="No recent jobs found" />
      </div>

      <.dm_table :if={@jobs != []} id="jobs-table" data={@jobs} hover zebra>
        <:col :let={job} label="Worker">
          <.link
            patch={~p"/system/logs/jobs?#{%{job_id: job.id}}"}
            class="font-mono text-xs text-primary underline"
          >
            {short_worker(job.worker)}
          </.link>
        </:col>
        <:col :let={job} label="Queue">{job.queue}</:col>
        <:col :let={job} label="State">
          <.dm_badge variant={state_badge_variant(job.state)} size="sm">{job.state}</.dm_badge>
        </:col>
        <:col :let={job} label="Attempt">{job.attempt}/{job.max_attempts}</:col>
        <:col :let={job} label="Started">
          <.local_time datetime={job.attempted_at} format="short" />
        </:col>
        <:col :let={job} label="Completed">
          <.local_time datetime={job.completed_at} format="short" />
        </:col>
      </.dm_table>
    </div>
    """
  end

  defp load_data(socket) do
    jobs = load_recent_jobs()
    selected_job = load_selected_job(socket.assigns.selected_job_id)

    assign(socket, loading: false, jobs: jobs, selected_job: selected_job)
  end

  defp load_selected_job(nil), do: nil

  defp load_selected_job(job_id) do
    from(j in "oban_jobs",
      where: j.id == ^job_id,
      select: %{
        id: j.id,
        worker: j.worker,
        queue: j.queue,
        state: j.state,
        attempt: j.attempt,
        max_attempts: j.max_attempts,
        errors: j.errors
      }
    )
    |> Repo.one()
    |> sanitize_job_errors()
  rescue
    _ -> nil
  end

  defp sanitize_job_errors(nil), do: nil

  defp sanitize_job_errors(job) do
    encoded = Jason.encode!(job.errors || [])
    {:ok, error_detail} = Filter.apply_bounded(encoded, 4_096)
    Map.put(job, :error_detail, error_detail)
  end

  defp parse_job_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_job_id(_value), do: nil

  defp load_recent_jobs do
    from(j in "oban_jobs",
      where: j.state in ["completed", "executing", "retryable", "discarded"],
      order_by: [desc: j.attempted_at],
      limit: ^@page_size,
      select: %{
        id: j.id,
        worker: j.worker,
        queue: j.queue,
        state: j.state,
        attempted_at: j.attempted_at,
        completed_at: j.completed_at,
        attempt: j.attempt,
        max_attempts: j.max_attempts
      }
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  defp short_worker(worker) when is_binary(worker) do
    worker
    |> String.split(".")
    |> Enum.take(-2)
    |> Enum.join(".")
  end

  defp short_worker(worker), do: to_string(worker)

  defp state_badge_variant("completed"), do: "success"
  defp state_badge_variant("executing"), do: "info"
  defp state_badge_variant("retryable"), do: "warning"
  defp state_badge_variant("discarded"), do: "error"
  defp state_badge_variant(_), do: "neutral"
end
