defmodule Backplane.HostAgent.Diagnostics.Sources do
  @moduledoc "Host configuration ties an environment-provided credential to each diagnostic producer."

  alias Backplane.DiagnosticsClient.Envelope

  @token_header "x-backplane-diagnostics-source"

  def source_header, do: @token_header

  def parse(list) when is_list(list) do
    list
    |> Enum.take(1_024)
    |> Enum.flat_map(fn attrs ->
      case parse_entry(attrs) do
        nil -> []
        source -> [source]
      end
    end)
    |> Enum.group_by(& &1.id)
    |> Map.filter(fn {_id, entries} -> length(entries) == 1 end)
    |> Map.new(fn {id, [source]} -> {id, source} end)
  end

  def parse(_), do: %{}

  def authenticate(sources, id, token)
      when is_binary(id) and is_binary(token) and byte_size(token) in 24..256 do
    with %{token_env: env} = source <- Map.get(sources, id),
         expected when is_binary(expected) and byte_size(expected) in 24..256 <-
           System.get_env(env),
         true <-
           :crypto.hash_equals(:crypto.hash(:sha256, expected), :crypto.hash(:sha256, token)) do
      {:ok, source}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate(_, _, _), do: {:error, :unauthorized}

  defp parse_entry(%{"id" => id, "application" => app, "token_env" => env} = attrs) do
    if Envelope.id?(id) and Envelope.id?(app) and is_binary(env) and byte_size(env) <= 128 and
         env =~ ~r/\A[A-Z_][A-Z0-9_]*\z/ and
         optional_text?(attrs["repository"], 256) and
         optional_text?(attrs["service_instance"], 128) do
      %{
        id: id,
        application: app,
        token_env: env,
        repository: attrs["repository"],
        service_instance: attrs["service_instance"],
        enabled: attrs["enabled"] != false,
        critical: attrs["critical"] == true
      }
    end
  end

  defp parse_entry(_), do: nil

  defp optional_text?(nil, _), do: true

  defp optional_text?(text, limit),
    do: is_binary(text) and byte_size(text) in 1..limit and String.valid?(text)
end
