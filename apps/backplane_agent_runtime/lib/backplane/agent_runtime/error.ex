defmodule Backplane.AgentRuntime.Error do
  @type class ::
          :validation
          | :forbidden
          | :approval_required
          | :not_found
          | :timeout
          | :cancelled
          | :transient_transport
          | :resource_conflict
          | :execution_failure
          | :malformed_result
          | :budget_exceeded
          | :unsupported_capability
          | :unknown_outcome
          | :overloaded

  @type t :: %__MODULE__{
          class: class(),
          message: String.t() | nil,
          details: map(),
          cause: term() | nil
        }

  defstruct class: :execution_failure, message: nil, details: %{}, cause: nil

  @valid_classes [
    :validation,
    :forbidden,
    :approval_required,
    :not_found,
    :timeout,
    :cancelled,
    :transient_transport,
    :resource_conflict,
    :execution_failure,
    :malformed_result,
    :budget_exceeded,
    :unsupported_capability,
    :unknown_outcome,
    :overloaded
  ]

  @spec new(term(), String.t() | nil, keyword()) :: t()
  def new(class, message \\ nil, opts \\ []) when is_list(opts) do
    class = normalize_class(class)

    %__MODULE__{
      class: class,
      message: message,
      details: Map.new(Keyword.get(opts, :details, [])),
      cause: Keyword.get(opts, :cause)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "class" => error.class,
      "message" => error.message,
      "details" => error.details
    }
  end

  defp normalize_class(class) when class in @valid_classes, do: class

  defp normalize_class(class) when is_atom(class) do
    raise ArgumentError, "unknown agent runtime error class #{inspect(class)}"
  end

  defp normalize_class(class) do
    raise ArgumentError, "agent runtime error class must be an atom, got #{inspect(class)}"
  end
end
