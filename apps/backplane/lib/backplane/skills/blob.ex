defmodule Backplane.Skills.Blob do
  @moduledoc """
  Storage behaviour for archived skill blobs.
  """

  @callback put(hash :: String.t(), chunks :: Enumerable.t()) :: :ok | {:error, term()}
  @callback get(hash :: String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  @callback exists?(hash :: String.t()) :: boolean()
  @callback delete(hash :: String.t()) :: :ok | {:error, term()}
end
