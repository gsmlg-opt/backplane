defmodule Backplane.HTTPClient.Response do
  @moduledoc "A completed `Backplane.HTTPClient` response with lowercase, multi-value headers."

  defstruct status: 0, headers: %{}, body: ""

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: %{optional(String.t()) => [String.t()]},
          body: term()
        }

  @doc "Returns every value of header `name` (case-insensitive)."
  @spec get_header(t(), String.t()) :: [String.t()]
  def get_header(%__MODULE__{headers: headers}, name),
    do: Map.get(headers, String.downcase(name), [])
end
