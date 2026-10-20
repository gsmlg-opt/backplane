defmodule Backplane.HostAgent.Memory.GitContext do
  @moduledoc "Offline Git discovery at the host boundary; discovery failure never rejects a write."

  alias Backplane.MemoryRepository

  @doc "Records cwd, Git checkout root, and a normalized remote identity when available."
  def discover(cwd, opts \\ [])

  def discover(cwd, opts) when is_binary(cwd) and cwd != "" do
    runner = Keyword.get(opts, :runner, &git/2)

    root =
      if Path.type(cwd) == :absolute, do: result(runner, cwd, ["rev-parse", "--show-toplevel"])

    remotes =
      if root do
        case result(runner, cwd, ["remote"]) do
          nil ->
            %{}

          names ->
            names
            |> String.split("\n", trim: true)
            |> Map.new(fn name ->
              {name, result(runner, cwd, ["config", "--get", "remote.#{name}.url"])}
            end)
        end
      else
        %{}
      end

    [
      %{
        "repository_id" => MemoryRepository.select_remote(remotes),
        "checkout_root" => root,
        "cwd" => cwd
      }
    ]
  end

  def discover(_cwd, _opts), do: []

  @doc "Adds provenance to explicit writes that supply a working directory or historical project path."
  def enrich_arguments(args) when is_map(args) do
    metadata = Map.get(args, "metadata", Map.get(args, :metadata, %{}))

    if is_map(metadata) do
      cwd = metadata["cwd"] || metadata[:cwd] || metadata["project"] || metadata[:project]
      metadata = MemoryRepository.metadata(metadata, discover(cwd))
      args |> Map.delete(:metadata) |> Map.put("metadata", metadata)
    else
      args
    end
  end

  defp result(runner, cwd, args) do
    case runner.(cwd, args) do
      {value, 0} when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp git(cwd, args) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_unavailable}

      executable ->
        System.cmd(executable, ["-C", cwd | args],
          stderr_to_stdout: true,
          env: [{"GIT_TERMINAL_PROMPT", "0"}]
        )
    end
  end
end
