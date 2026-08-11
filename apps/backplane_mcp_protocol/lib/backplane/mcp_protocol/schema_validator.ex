defmodule Backplane.McpProtocol.SchemaValidator do
  @moduledoc """
  Adapter boundary between JSON Schema wire documents and local validation.

  Wire schemas are always retained independently of whether an adapter can
  validate them. Adapters must decline unsupported vocabulary explicitly
  rather than applying a lossy interpretation.
  """

  @type compiled :: term()
  @type reason :: term()

  @callback compile(map(), keyword()) ::
              {:ok, compiled()} | {:unsupported, reason()} | {:error, reason()}
  @callback validate(compiled(), term(), keyword()) :: :ok | {:error, reason()}
end
