defmodule Backplane.HostAgent.Memory.Edge.Protection do
  @moduledoc "Fail-closed edge persistence policy, fixed by the compiled build environment."
  @build_env Mix.env()

  if @build_env in [:dev, :test] do
    defp development_status(config) do
      if Map.get(config, :development_plaintext) == true,
        do: :plaintext_development,
        else: :protection_unavailable
    end
  else
    defp development_status(_config), do: :protection_unavailable
  end

  def status(config) do
    cond do
      Map.get(config, :enabled, false) != true ->
        :disabled

      reserved_path?(config) ->
        :protection_unavailable

      true ->
        development_status(config)
    end
  end

  defp reserved_path?(config) do
    path = Map.get(config, :db_path)

    is_binary(path) and
      Enum.any?(
        Map.get(config, :reserved_db_paths, []),
        &(is_binary(&1) and same_database?(&1, path))
      )
  end

  defp same_database?(left, right) do
    Path.expand(left) == Path.expand(right) or
      case {File.stat(left), File.stat(right)} do
        {{:ok, a}, {:ok, b}} ->
          {a.major_device, a.minor_device, a.inode} == {b.major_device, b.minor_device, b.inode}

        _ ->
          false
      end
  end
end
