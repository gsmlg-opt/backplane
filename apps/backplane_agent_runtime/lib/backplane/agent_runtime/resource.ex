defmodule Backplane.AgentRuntime.Resource do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Scoped resource operations with revision-safe writes and bounded output.

  The adapter owns real confinement. This module validates references, expected
  revisions, and output bounds without pretending `Path.expand` is a sandbox.
  """

  @type t :: map()

  @callback read(map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}

  @callback write(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}

  @default_output_limit 1_048_576

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(namespace) when is_map(namespace) do
    with {:ok, adapter} <- validate_adapter(namespace),
         {:ok, scope} <- require_binary(namespace, :scope, "scope") do
      {:ok, %{namespace: namespace, adapter: adapter, scope: scope}}
    end
  end

  @spec read(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def read(resource, reference, opts \\ []) when is_map(resource) and is_map(reference) do
    with {:ok, _} <- validate_reference(resource, reference),
         {:ok, result} <- resource.adapter.read(resource, reference, opts) do
      validate_output(result, opts)
    end
  end

  @spec write(t(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def write(resource, reference, content, opts \\ [])
      when is_map(resource) and is_map(reference) and is_map(content) do
    with {:ok, _} <- validate_reference(resource, reference),
         {:ok, revision} <- require_expected_revision(reference) do
      if revision != Map.get(content, :expected_revision, revision) do
        {:error, Error.new(:resource_conflict, "resource revision conflict")}
      else
        resource.adapter.write(resource, reference, content, opts)
      end
    end
  end

  defp validate_reference(resource, reference) do
    scope = resource.scope
    path = Map.get(reference, :path)

    if is_binary(path) and String.starts_with?(path, scope) do
      {:ok, path}
    else
      {:error, Error.new(:forbidden, "resource reference is outside declared scope")}
    end
  end

  defp require_expected_revision(reference) do
    revision = Map.get(reference, :expected_revision)

    if is_integer(revision) and revision >= 0 do
      {:ok, revision}
    else
      {:error, Error.new(:validation, "expected_revision is required")}
    end
  end

  defp validate_output(result, opts) do
    limit = Keyword.get(opts, :output_limit, @default_output_limit)
    size = :erlang.external_size(result)

    if size > limit do
      {:error,
       Error.new(:resource_conflict, "resource output exceeds the configured bound",
         details: %{limit: limit, size: size}
       )}
    else
      {:ok, result}
    end
  end

  defp require_binary(input, key, label) do
    value = Map.get(input, key)

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, Error.new(:validation, "#{label} is required")}
    end
  end

  defp validate_adapter(namespace) do
    adapter = Map.get(namespace, :adapter)

    if is_atom(adapter) do
      {:ok, adapter}
    else
      {:error, Error.new(:validation, "adapter is required")}
    end
  end
end
