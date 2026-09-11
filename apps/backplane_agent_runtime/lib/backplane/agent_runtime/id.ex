defmodule Backplane.AgentRuntime.ID do
  @opaque t :: binary()

  @doc """
  Creates an opaque serializable runtime identifier. Callers inject the
  generator so the execution kernel remains deterministic.
  """
  @spec new(binary()) :: t()
  def new(prefix) when is_binary(prefix) do
    random =
      :crypto.strong_rand_bytes(16)
      |> Base.url_encode64(padding: false)

    "#{prefix}_#{random}"
  end

  @doc """
  Validates an externally supplied runtime identifier without interpreting it.
  """
  @spec validate(term(), binary()) :: {:ok, t()} | {:error, Backplane.AgentRuntime.Error.t()}
  def validate(value, prefix) when is_binary(value) and is_binary(prefix) do
    if String.starts_with?(value, "#{prefix}_") and
         String.length(value) > String.length(prefix) + 1 do
      {:ok, value}
    else
      {:error,
       Backplane.AgentRuntime.Error.new(
         :validation,
         "invalid #{prefix} identifier",
         details: %{expected_prefix: "#{prefix}_"}
       )}
    end
  end

  def validate(value, prefix) do
    {:error,
     Backplane.AgentRuntime.Error.new(:validation, "invalid #{prefix} identifier",
       details: %{expected: "binary", received: value}
     )}
  end
end
