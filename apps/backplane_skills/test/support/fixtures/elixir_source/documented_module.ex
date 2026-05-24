defmodule Example.Documented do
  @moduledoc """
  A fully documented example module for testing the Elixir parser.

  This module contains @moduledoc, @doc, @spec, @type, and @typedoc
  annotations to exercise all parser extraction paths.
  """

  @typedoc "A user identifier, either numeric or string-based."
  @type user_id :: integer() | String.t()

  @typedoc "Options for user creation."
  @type create_opts :: [name: String.t(), email: String.t()]

  @doc """
  Creates a new user with the given name.

  Returns `{:ok, user}` on success or `{:error, reason}` on failure.
  """
  @spec create(String.t()) :: {:ok, map()} | {:error, term()}
  def create(name) when is_binary(name) do
    {:ok, %{name: name, id: System.unique_integer([:positive])}}
  end

  @doc "Returns the greeting for a user."
  @spec greet(map()) :: String.t()
  def greet(%{name: name}), do: "Hello, #{name}!"

  @doc false
  def internal_helper, do: :ok

  defp private_function, do: :secret
end
