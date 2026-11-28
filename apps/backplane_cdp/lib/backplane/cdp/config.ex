defmodule Backplane.CDP.Config do
  @moduledoc """
  Resolves host-agent CDP settings from `:backplane_cdp, :config`.

  Each configured atom key takes precedence over its environment fallback.
  Explicit disablement overrides a configured or environment debugging port.
  """

  def enabled?, do: match?({:ok, _}, port())

  def port do
    with {:ok, config} <- config() do
      case Map.fetch(config, :enabled) do
        {:ok, false} ->
          {:error, "Chrome DevTools is disabled by cdp.enabled in the host config"}

        {:ok, true} ->
          configured_port(config, 9222)

        :error ->
          configured_port(config, nil)

        {:ok, _value} ->
          {:error, "Set cdp.enabled in the host config to true or false"}
      end
    end
  end

  def artifact_dir do
    directory(:artifact_dir, "BACKPLANE_CDP_ARTIFACT_DIR", "enable named file output")
  end

  def upload_dir do
    directory(
      :upload_dir,
      "BACKPLANE_CDP_UPLOAD_DIR",
      "enable file uploads and script file access"
    )
  end

  defp config do
    case Application.get_env(:backplane_cdp, :config, %{}) do
      config when is_map(config) ->
        {:ok, config}

      _ ->
        {:error, "CDP configuration must be a map of enabled, port, artifact_dir and upload_dir"}
    end
  end

  defp configured_port(config, default) do
    case Map.fetch(config, :port) do
      {:ok, port} when is_integer(port) and port in 1..65_535 ->
        {:ok, port}

      {:ok, _port} ->
        {:error, "Set cdp.port in the host config to an integer between 1 and 65535"}

      :error ->
        environment_port(default)
    end
  end

  defp environment_port(default) do
    case System.get_env("BACKPLANE_CDP_PORT") do
      port when port in [nil, ""] ->
        if default,
          do: {:ok, default},
          else:
            {:error,
             "Enable CDP with cdp.enabled or cdp.port in the host config, or BACKPLANE_CDP_PORT"}

      value ->
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 ->
            {:ok, port}

          _ ->
            {:error,
             "Set BACKPLANE_CDP_PORT to an integer between 1 and 65535, or configure cdp.port in the host config"}
        end
    end
  end

  defp directory(key, environment, purpose) do
    with {:ok, config} <- config() do
      root =
        case Map.fetch(config, key) do
          {:ok, root} -> root
          :error -> System.get_env(environment)
        end

      if is_binary(root) and root != "" and File.dir?(Path.expand(root)) do
        {:ok, Path.expand(root)}
      else
        {:error,
         "Set cdp.#{key} in the host config or #{environment} to an existing directory to #{purpose}"}
      end
    end
  end
end
