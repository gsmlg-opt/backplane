defmodule Backplane.Skills.Blob do
  @moduledoc """
  Facade for skill archive blob storage.
  """

  alias Backplane.Skills.Blob.LocalFS

  @type blob_ref :: String.t()

  @spec put(binary(), keyword()) :: {:ok, blob_ref()} | {:error, term()}
  def put(bytes, opts \\ []), do: LocalFS.put(bytes, opts)

  @spec put_file(String.t(), keyword()) :: {:ok, blob_ref()} | {:error, term()}
  def put_file(path, opts \\ []), do: LocalFS.put_file(path, opts)

  @spec get(blob_ref(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def get(ref, opts \\ []), do: LocalFS.get(ref, opts)

  @spec exists?(blob_ref(), keyword()) :: boolean()
  def exists?(ref, opts \\ []), do: LocalFS.exists?(ref, opts)

  @spec delete(blob_ref(), keyword()) :: :ok | {:error, term()}
  def delete(ref, opts \\ []), do: LocalFS.delete(ref, opts)
end
