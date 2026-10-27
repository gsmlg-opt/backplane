defmodule Mix.Tasks.Backplane.Mcp.Stdio.Build do
  @shortdoc "Explicitly builds and probes the verified MCP stdio guardian"
  @moduledoc """
  Builds the package-owned Linux/macOS POSIX guardian. No ordinary Mix compiler,
  application startup or transport activation invokes a compiler.

      mix backplane.mcp.stdio.build
      mix backplane.mcp.stdio.build --output /absolute/package/priv/bin/backplane-mcp-stdio-guardian

  CC may select the platform C11 compiler. The output must pass protocol probe 1.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])
    if rest != [] or invalid != [], do: Mix.raise("Expected only --output PATH")
    root = Path.expand("../../..", __DIR__)
    script = Path.join(root, "c_src/build_stdio_guardian.sh")
    output = Keyword.get(opts, :output, Path.join(root, "priv/bin/backplane-mcp-stdio-guardian"))

    case System.cmd("sh", [script, Path.expand(output)], stderr_to_stdout: true) do
      {text, 0} -> Mix.shell().info(String.trim(text))
      {text, status} -> Mix.raise("MCP stdio guardian build failed (#{status}): #{text}")
    end
  end
end
