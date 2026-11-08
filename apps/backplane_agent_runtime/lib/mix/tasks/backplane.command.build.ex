defmodule Mix.Tasks.Backplane.Command.Build do
  use Mix.Task

  @shortdoc "Build the LocalCommand session helper for macOS or Linux"
  @moduledoc """
  Builds the packaged C11 session launcher and process probes. macOS LocalCommand
  requires this helper; ordinary compilation does not build native code.
  Requires a C compiler and platform headers. Honors the trusted `CC` environment.
  """
  @impl Mix.Task
  def run([]) do
    unless :os.type() in [{:unix, :linux}, {:unix, :darwin}],
      do: Mix.raise("The LocalCommand helper requires Linux or macOS")

    source = source_directory()
    output = Path.join(source, "priv/bin/backplane-local-command-session")

    {text, status} =
      System.cmd("sh", [Path.join(source, "c_src/build_command.sh"), output],
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("LocalCommand helper build failed (#{status}): #{text}")
    # Dependencies may have a copied priv directory rather than Mix's usual symlink.
    compiled =
      Application.app_dir(:backplane_agent_runtime, "priv/bin/backplane-local-command-session")

    if Path.expand(compiled) != Path.expand(output) and not same_file?(compiled, output) do
      File.mkdir_p!(Path.dirname(compiled))
      File.cp!(output, compiled)
      File.chmod!(compiled, 0o755)
    end

    Mix.shell().info("Built LocalCommand session helper: #{output}")
  end

  def run(_), do: Mix.raise("Usage: mix backplane.command.build")

  defp source_directory do
    cond do
      Mix.Project.config()[:app] == :backplane_agent_runtime ->
        File.cwd!()

      File.regular?(
        Path.join([File.cwd!(), "apps", "backplane_agent_runtime", "c_src", "build_command.sh"])
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
