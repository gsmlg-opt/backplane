defmodule BackplaneWeb.GitProvidersLive do
  use BackplaneWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/admin/git", loading: true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    providers = load_git_providers()
    {:noreply, assign(socket, loading: false, providers: providers)}
  end

  defp load_git_providers do
    git_config = Application.get_env(:backplane, :git_providers, %{})

    github =
      (git_config[:github] || [])
      |> Enum.map(fn {name, config} ->
        %{
          name: to_string(name),
          type: "GitHub",
          api_url: config[:api_url] || "https://api.github.com"
        }
      end)

    gitlab =
      (git_config[:gitlab] || [])
      |> Enum.map(fn {name, config} ->
        %{
          name: to_string(name),
          type: "GitLab",
          api_url: config[:api_url] || "https://gitlab.com/api/v4"
        }
      end)

    github ++ gitlab
  rescue
    _ -> []
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-2xl font-bold text-white mb-6">Git Providers</h1>

      <div :if={@providers == []} class="text-gray-400">
        No git providers configured. Add [github] or [gitlab] sections to your backplane.toml.
      </div>

      <div class="space-y-4">
        <div
          :for={provider <- @providers}
          class="bg-gray-900 border border-gray-800 rounded-lg p-4"
        >
          <div class="flex items-center justify-between">
            <h3 class="text-sm font-medium text-white">{provider.name}</h3>
            <span class={[
              "text-xs px-2 py-0.5 rounded",
              if(provider.type == "GitHub",
                do: "bg-gray-800 text-gray-300",
                else: "bg-orange-900/50 text-orange-300"
              )
            ]}>
              {provider.type}
            </span>
          </div>
          <p class="text-xs text-gray-400 mt-1">{provider.api_url}</p>
        </div>
      </div>
    </div>
    """
  end
end
