defmodule Backplane.AiProtocol.Lifecycle do
  @moduledoc """
  Pure lifecycle transitions for one local execution handle.
  """

  alias Backplane.AiProtocol.Error

  defstruct [:terminal]

  @type status :: :completed | :incomplete | :failed | :cancelled | :interrupted
  @type t :: %__MODULE__{terminal: map() | nil}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec start_attempt(t() | {:ok, t()} | {:error, Error.t()}) ::
          {:ok, t()} | {:error, Error.t()}
  def start_attempt({:ok, %__MODULE__{} = lifecycle}), do: start_attempt(lifecycle)
  def start_attempt({:error, _error} = error), do: error
  def start_attempt(%__MODULE__{terminal: nil}), do: {:ok, %__MODULE__{}}
  def start_attempt(%__MODULE__{}), do: {:error, Error.invalid!("Lifecycle already finished")}

  @type finish_status :: :complete | :incomplete

  @spec finish(t() | {:ok, t()} | {:error, Error.t()}, finish_status(), atom()) ::
          {:ok, t()} | {:error, Error.t()}
  def finish({:ok, %__MODULE__{} = lifecycle}, status, stop_reason),
    do: finish(lifecycle, status, stop_reason)

  def finish({:error, _error} = error, _status, _stop_reason), do: error

  def finish(%__MODULE__{terminal: nil}, :complete, stop_reason) do
    {:ok, %__MODULE__{terminal: %{status: :completed, stop_reason: stop_reason}}}
  end

  def finish(%__MODULE__{terminal: nil}, :incomplete, stop_reason) do
    {:ok, %__MODULE__{terminal: %{status: :incomplete, stop_reason: stop_reason}}}
  end

  def finish(%__MODULE__{}, _status, _stop_reason),
    do: {:error, Error.invalid!("Lifecycle already finished")}

  @spec cancel(t() | {:ok, t()} | {:error, Error.t()}, :known | :unknown) ::
          {:ok, t()} | {:error, Error.t()}
  def cancel({:ok, %__MODULE__{} = lifecycle}, upstream_outcome),
    do: cancel(lifecycle, upstream_outcome)

  def cancel({:error, _error} = error, _upstream_outcome), do: error

  def cancel(%__MODULE__{terminal: nil}, upstream_outcome)
      when upstream_outcome in [:known, :unknown] do
    {:ok, %__MODULE__{terminal: %{status: :cancelled, upstream_outcome: upstream_outcome}}}
  end

  def cancel(%__MODULE__{terminal: nil}, _upstream_outcome),
    do: {:error, Error.invalid!("Cancellation upstream outcome must be known or unknown")}

  def cancel(%__MODULE__{}, _upstream_outcome),
    do: {:error, Error.invalid!("Lifecycle already finished")}

  @spec interrupt(t() | {:ok, t()} | {:error, Error.t()}, :known | :unknown) ::
          {:ok, t()} | {:error, Error.t()}
  def interrupt({:ok, %__MODULE__{} = lifecycle}, upstream_outcome),
    do: interrupt(lifecycle, upstream_outcome)

  def interrupt({:error, _error} = error, _upstream_outcome), do: error

  def interrupt(%__MODULE__{terminal: nil}, upstream_outcome)
      when upstream_outcome in [:known, :unknown] do
    {:ok, %__MODULE__{terminal: %{status: :interrupted, upstream_outcome: upstream_outcome}}}
  end

  def interrupt(%__MODULE__{terminal: nil}, _upstream_outcome),
    do: {:error, Error.invalid!("Interruption upstream outcome must be known or unknown")}

  def interrupt(%__MODULE__{}, _upstream_outcome),
    do: {:error, Error.invalid!("Lifecycle already finished")}

  @spec fail(t() | {:ok, t()} | {:error, Error.t()}, atom()) :: {:ok, t()} | {:error, Error.t()}
  def fail({:ok, %__MODULE__{} = lifecycle}, kind), do: fail(lifecycle, kind)
  def fail({:error, _error} = error, _kind), do: error

  def fail(%__MODULE__{terminal: nil}, kind) do
    {:ok, %__MODULE__{terminal: %{status: :failed, kind: kind}}}
  end

  def fail(%__MODULE__{}, _kind), do: {:error, Error.invalid!("Lifecycle already finished")}

  @spec terminal(t() | {:ok, t()} | {:error, Error.t()}) :: {:ok, map()} | {:error, Error.t()}
  def terminal({:ok, %__MODULE__{} = lifecycle}), do: terminal(lifecycle)
  def terminal({:error, _error} = error), do: error
  def terminal(%__MODULE__{terminal: terminal}) when terminal != nil, do: {:ok, terminal}
  def terminal(%__MODULE__{}), do: {:error, Error.invalid!("Lifecycle is not terminal")}
end
