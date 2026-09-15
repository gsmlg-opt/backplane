defmodule Backplane.SkillProtocol.Validator do
  @moduledoc "Separate strict and legacy validation profiles."

  alias Backplane.SkillProtocol.{Diagnostic, Document, Error}

  @name ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @spec validate(Document.t(), keyword()) :: {:ok, Document.t()} | {:error, Error.t()}
  def validate(%Document{} = document, opts \\ []) do
    profile = Keyword.get(opts, :profile, :standard)
    diagnostics = diagnostics(document, profile, opts)
    errors = Enum.filter(diagnostics, &(&1.severity == :error))

    if errors == [] do
      {:ok, %{document | diagnostics: diagnostics}}
    else
      {:error,
       Error.new(:invalid_document, :validate, "document failed #{profile} validation",
         context: %{diagnostics: diagnostics}
       )}
    end
  end

  defp diagnostics(document, profile, opts) do
    []
    |> require_name(document, profile)
    |> require_description(document, profile)
    |> validate_invocation(document)
    |> validate_capabilities(document, opts)
    |> Enum.reverse()
  end

  defp require_name(acc, %Document{name: name}, :legacy) when is_binary(name) and name != "",
    do: acc

  defp require_name(acc, %Document{name: name}, _profile) when is_binary(name) and name != "" do
    if Regex.match?(@name, name),
      do: acc,
      else: [diag(:invalid_name, "name must be lowercase kebab-case") | acc]
  end

  defp require_name(acc, _document, _profile), do: [diag(:missing_name, "name is required") | acc]

  defp require_description(acc, %Document{description: value}, _profile)
       when is_binary(value) and value != "",
       do: acc

  defp require_description(acc, _document, :legacy),
    do: [diag(:missing_description, "description is missing", :warning) | acc]

  defp require_description(acc, _document, _profile),
    do: [diag(:missing_description, "description is required") | acc]

  defp validate_invocation(acc, %Document{metadata: metadata}) do
    Enum.reduce(["disable-model-invocation", "user-invocable"], acc, fn key, current ->
      case Map.fetch(metadata, key) do
        :error ->
          current

        {:ok, value} when is_boolean(value) ->
          current

        {:ok, _} ->
          [
            diag(:invalid_invocation_flag, "#{key} must be boolean", :error, %{field: key})
            | current
          ]
      end
    end)
  end

  defp validate_capabilities(acc, %Document{metadata: metadata}, opts) do
    supported = MapSet.new(Keyword.get(opts, :supported_capabilities, []))
    case Map.fetch(metadata, "backplane") do
      :error -> acc
      {:ok, nil} -> acc
      {:ok, []} -> acc
      {:ok, extension} when is_map(extension) -> validate_required_capabilities(acc, extension, supported)
      {:ok, _extension} -> [diag(:invalid_backplane_extension, "backplane metadata must be an object") | acc]
    end
  end

  defp validate_required_capabilities(acc, extension, supported) do
    case Map.fetch(extension, "required-capabilities") do
      :error -> acc
      {:ok, nil} -> acc
      {:ok, required} when is_list(required) ->
        invalid = Enum.reject(required, &is_binary/1)
        missing = Enum.reject(required, &(MapSet.member?(supported, &1)))

        acc
        |> then(fn current ->
          if invalid == [],
            do: current,
            else: [
              diag(:invalid_required_capabilities, "required capabilities must be a list of strings", :error, %{invalid: invalid})
              | current
            ]
        end)
        |> then(fn current ->
          if invalid == [] and missing != [],
            do: [diag(:unsupported_capability, "a required capability is unsupported", :error, %{capabilities: missing}) | current],
            else: current
        end)

      {:ok, _required} -> [diag(:invalid_required_capabilities, "required capabilities must be a list of strings") | acc]
    end
  end

  defp diag(code, message, severity \\ :error, context \\ %{}),
    do: Diagnostic.new(code, :validate, severity, message, context)
end
