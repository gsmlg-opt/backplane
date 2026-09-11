defmodule Backplane.AiProtocol.ExecutionGate do
  @moduledoc """
  Single-use execution handle gate.

  This is a pure state transition. Runtime wrappers own actual process/supervision effects.
  """

  alias Backplane.AiProtocol.Error

  defstruct [:handle, claimed: false, finished: false]

  @type t :: %__MODULE__{handle: term() | nil, claimed: boolean(), finished: boolean()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec open(t()) :: {:ok, t()} | {:error, Error.t()}
  def open(%__MODULE__{handle: nil}) do
    {:ok, %__MODULE__{handle: make_ref()}}
  end

  def open(%__MODULE__{}), do: {:error, Error.invalid!("Execution gate already open")}

  @spec claim(t()) :: {:ok, t()} | {:error, Error.t()}
  def claim(%__MODULE__{handle: nil}), do: {:error, Error.invalid!("Execution gate is not open")}

  def claim(%__MODULE__{claimed: true}), do: {:error, Error.invalid!("Execution already claimed")}

  def claim(%__MODULE__{} = gate), do: {:ok, %{gate | claimed: true}}

  @spec finish(t()) :: {:ok, t()} | {:error, Error.t()}
  def finish(%__MODULE__{handle: nil}), do: {:error, Error.invalid!("Execution gate is not open")}
  def finish(%__MODULE__{finished: true}), do: {:error, Error.invalid!("Execution already finished")}

  def finish(%__MODULE__{} = gate), do: {:ok, %{gate | finished: true}}
end
