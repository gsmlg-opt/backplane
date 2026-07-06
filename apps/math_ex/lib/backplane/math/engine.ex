defmodule Backplane.Math.Engine do
  @moduledoc "Behaviour for math engines."

  @type op :: atom()
  @type params :: map()
  @type value :: term()

  @callback describe() :: %{id: atom(), version: String.t()}
  @callback supports?(op()) :: boolean()
  @callback run(op(), params()) :: {:ok, value()} | {:error, term()}
end
