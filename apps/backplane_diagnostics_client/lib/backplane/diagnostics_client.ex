defmodule Backplane.DiagnosticsClient do
  @moduledoc "Supervises a Reporter and the application's opted-in exception hooks."

  use Supervisor

  alias Backplane.DiagnosticsClient.{Integrations, Reporter}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @doc "Builds child options from optional, deployment-scoped diagnostics settings."
  def from_env(application, opts \\ []) do
    case {System.get_env("BACKPLANE_DIAGNOSTICS_HOST_URL"),
          System.get_env("BACKPLANE_DIAGNOSTICS_SOURCE_ID")} do
      {url, source_id} when url not in [nil, ""] and source_id not in [nil, ""] ->
        version = Keyword.get(opts, :version, %{})

        version =
          put_version(
            version,
            "git_sha",
            System.get_env("BACKPLANE_DIAGNOSTICS_GIT_SHA"),
            ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
          )

        version =
          put_version(
            version,
            "release",
            System.get_env("BACKPLANE_DIAGNOSTICS_RELEASE"),
            ~r/\A[^\x00-\x1f]{1,128}\z/
          )

        instance = System.get_env("BACKPLANE_DIAGNOSTICS_SERVICE_INSTANCE")

        opts =
          if Backplane.DiagnosticsClient.Envelope.id?(instance),
            do: Keyword.put(opts, :service_instance, instance),
            else: opts

        Keyword.merge(opts,
          application: application,
          host_url: url,
          source_id: source_id,
          token_env: "BACKPLANE_DIAGNOSTICS_TOKEN",
          version: version
        )

      _ ->
        nil
    end
  end

  defp put_version(version, key, value, pattern) do
    if is_binary(value) and byte_size(value) <= 128 and Regex.match?(pattern, value),
      do: Map.put(version, key, value),
      else: version
  end

  @impl true
  def init(opts) do
    Supervisor.init([{Reporter, opts}, {Integrations.Hooks, opts}], strategy: :rest_for_one)
  end
end
