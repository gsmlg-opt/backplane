defmodule DayEx.Locale do
  @moduledoc "Behaviour for DayEx locale modules."

  @callback months_full() :: [String.t()]
  @callback months_short() :: [String.t()]
  @callback weekdays_full() :: [String.t()]
  @callback weekdays_short() :: [String.t()]
  @callback weekdays_min() :: [String.t()]
  @callback relative_time() :: map()
  @callback ordinal(integer()) :: String.t()
  @callback week_start() :: 0..6
  @callback meridiem_upper() :: {String.t(), String.t()}
  @callback meridiem_lower() :: {String.t(), String.t()}

  @doc "Get locale module for a given locale atom."
  def get(locale) do
    module = Module.concat(__MODULE__, locale |> Atom.to_string() |> String.capitalize() |> String.to_atom())
    if Code.ensure_loaded?(module), do: module, else: DayEx.Locale.En
  end
end
