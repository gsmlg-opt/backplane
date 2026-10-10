defmodule Backplane.Admin.BuildInfo do
  @moduledoc """
  Application version and build metadata for the admin interface.

  Local Git metadata and build time are captured at compilation. Deployment
  metadata can override them at runtime; release time requires an explicit value.
  """

  @compiled_info (
                   git = fn args ->
                     try do
                       case System.cmd("git", ["-C", __DIR__ | args], stderr_to_stdout: true) do
                         {output, 0} -> String.trim(output)
                         _ -> nil
                       end
                     rescue
                       ErlangError -> nil
                     end
                   end

                   %{
                     environment: Atom.to_string(Mix.env()),
                     git_ref: git.(["rev-parse", "--abbrev-ref", "HEAD"]),
                     git_sha: git.(["rev-parse", "--verify", "HEAD"]),
                     built_at: DateTime.utc_now() |> DateTime.to_iso8601()
                   }
                 )

  @metadata_env ~w(BACKPLANE_GIT_REF BACKPLANE_GIT_SHA VCS_REF BACKPLANE_BUILD_DATE BACKPLANE_RELEASE_DATE)

  def current do
    version = Application.spec(:backplane_admin, :vsn) || Application.spec(:backplane, :vsn)
    env = Map.new(@metadata_env, &{&1, System.get_env(&1)})
    normalize_metadata(version, @compiled_info, env)
  end

  def label(info) do
    suffix = if info.environment == "dev", do: "-dev", else: ""
    "v#{info.version}#{suffix}"
  end

  def tooltip(info) do
    """
    Version: #{info.version}
    Environment: #{info.environment}
    Git ref: #{info.git_ref}
    Commit: #{info.git_sha}
    Build time: #{info.built_at}
    Release time: #{info.released_at}
    """
    |> String.trim_trailing()
  end

  @doc false
  def normalize_metadata(version, compiled, env) do
    %{
      version: present(version) || "Not provided",
      environment: present(compiled[:environment]) || "Not provided",
      git_ref: present(env["BACKPLANE_GIT_REF"]) || present(compiled[:git_ref]) || "Not provided",
      git_sha:
        present(env["BACKPLANE_GIT_SHA"]) || present(env["VCS_REF"]) ||
          present(compiled[:git_sha]) || "Not provided",
      built_at:
        present(env["BACKPLANE_BUILD_DATE"]) || present(compiled[:built_at]) || "Not provided",
      released_at: present(env["BACKPLANE_RELEASE_DATE"]) || "Not provided"
    }
  end

  defp present(nil), do: nil

  defp present(value) do
    value = value |> to_string() |> String.trim()
    if String.downcase(value) in ["", "unknown", "not provided"], do: nil, else: value
  end
end
