defmodule Mix.Tasks.Cdp do
  use Mix.Task

  @shortdoc "Run a Chrome DevTools command (mix cdp --help)"
  @requirements ["compile"]

  @impl true
  def run(argv) do
    case Backplane.CDP.CLI.run(argv) do
      {:ok, output} -> Mix.shell().info(output)
      {:error, message} -> Mix.raise(message)
    end
  end
end
