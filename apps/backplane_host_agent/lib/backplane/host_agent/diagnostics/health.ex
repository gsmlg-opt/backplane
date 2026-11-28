defmodule Backplane.HostAgent.Diagnostics.Health do
  @moduledoc "Provides bounded diagnostics status independently of the ordinary events channel."

  alias Backplane.HostAgent.Diagnostics.{Spool, Uploader}
  alias Backplane.HostAgent.Diagnostics.Collectors.Runner

  def summary(%{enabled: true, max_bytes: limit}) do
    %{
      "status" => safe(fn -> Atom.to_string(Uploader.status()) end, "unavailable"),
      "max_bytes" => limit,
      "collectors" => safe(&Runner.health/0, nil),
      "queue" =>
        safe(
          fn ->
            case Spool.health(Spool) do
              {:ok, rows} -> rows
              {:error, _} -> nil
            end
          end,
          nil
        )
    }
  end

  def summary(_), do: %{"status" => "disabled"}

  defp safe(fun, fallback) do
    fun.()
  catch
    :exit, _reason -> fallback
  end
end
