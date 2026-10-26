defmodule Mix.Tasks.Backplane.Pty.Build do
  use Mix.Task

  @shortdoc "Build the optional first-party Linux LocalCommand PTY helper"
  @moduledoc """
  Builds the packaged C11 source for the current Linux target and verifies real
  PTY/pidfd capabilities. Ordinary compilation does not invoke this task.
  Requires a C compiler and Linux headers. Honors the trusted `CC` environment.
  """
  @impl Mix.Task
  def run([]) do
    unless :os.type() == {:unix, :linux}, do: Mix.raise("The optional PTY helper requires Linux")
    source = source_directory()
    output = Path.join(source, "priv/bin/backplane-local-command-pty")

    {text, status} =
      System.cmd("sh", [Path.join(source, "c_src/build_pty.sh"), output], stderr_to_stdout: true)

    if status != 0, do: Mix.raise("PTY helper build failed (#{status}): #{text}")
    # Dependencies may have a copied priv directory rather than Mix's usual symlink.
    compiled =
      Application.app_dir(:backplane_agent_runtime, "priv/bin/backplane-local-command-pty")

    if Path.expand(compiled) != Path.expand(output) and not same_file?(compiled, output) do
      File.mkdir_p!(Path.dirname(compiled))
      File.cp!(output, compiled)
      File.chmod!(compiled, 0o755)
    end

    Mix.shell().info("Built optional PTY helper: #{output}")
  end

  def run(_), do: Mix.raise("Usage: mix backplane.pty.build")

  defp source_directory do
    cond do
      Mix.Project.config()[:app] == :backplane_agent_runtime ->
        File.cwd!()

      File.regular?(
        Path.join([File.cwd!(), "apps", "backplane_agent_runtime", "c_src", "build_pty.sh"])
      ) ->
        Path.join(File.cwd!(), "apps/backplane_agent_runtime")

      true ->
        case Enum.find(Mix.Dep.cached(), &(&1.app == :backplane_agent_runtime)) do
          nil -> Mix.raise("Cannot locate packaged backplane_agent_runtime native source")
          dep -> dep.opts[:dest]
        end
    end
  end

  defp same_file?(left, right) do
    with {:ok, l} <- File.stat(left), {:ok, r} <- File.stat(right) do
      l.inode == r.inode and l.major_device == r.major_device
    else
      _ -> false
    end
  end
end
