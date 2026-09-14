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

  @callback list_dir(map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}

  @callback glob(map(), map(), binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}

  @callback grep(map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}

  @callback file_edit(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}

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
      validate_output(result, opts, Keyword.get(opts, :partial_output?, false))
    end
  end

  @spec write(t(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def write(resource, reference, content, opts \\ [])
      when is_map(resource) and is_map(reference) and is_map(content) do
    with {:ok, _} <- validate_reference(resource, reference),
         {:ok, revision} <- require_write_revision(reference) do
      if revision != Map.get(content, :expected_revision, revision) do
        {:error, Error.new(:resource_conflict, "resource revision conflict")}
      else
        resource.adapter.write(resource, reference, content, opts)
      end
    end
  end

  @spec list_dir(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_dir(resource, reference, opts \\ []) when is_map(resource) and is_map(reference) do
    with {:ok, _} <- validate_reference(resource, reference) do
      resource.adapter.list_dir(resource, reference, opts)
    end
  end

  @spec glob(t(), map(), binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def glob(resource, reference, pattern, opts \\ [])
      when is_map(resource) and is_map(reference) and is_binary(pattern) and is_list(opts) do
    with {:ok, _} <- validate_reference(resource, reference) do
      resource.adapter.glob(resource, reference, pattern, opts)
    end
  end

  @spec grep(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def grep(resource, reference, opts \\ []) when is_map(resource) and is_map(reference) do
    with {:ok, _} <- validate_reference(resource, reference) do
      resource.adapter.grep(resource, reference, opts)
    end
  end

  @spec file_edit(t(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def file_edit(resource, reference, content, opts \\ [])
      when is_map(resource) and is_map(reference) and is_map(content) and is_list(opts) do
    with {:ok, _} <- validate_reference(resource, reference) do
      resource.adapter.file_edit(resource, reference, content, opts)
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

  defp require_write_revision(reference) do
    if Map.get(reference, :create_only?, false) and
         is_nil(Map.get(reference, :expected_revision)) do
      {:ok, 0}
    else
      require_expected_revision(reference)
    end
  end

  defp validate_output(result, opts, allow_partial_output?) do
    limit = Keyword.get(opts, :output_limit, @default_output_limit)
    size = :erlang.external_size(result)

    if not allow_partial_output? and size > limit do
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
