defmodule Backplane.Utils do
  @moduledoc """
  Shared utility functions used across Backplane modules.
  """

  @doc """
  Conditionally adds a key-value pair to a keyword list.
  Returns the list unchanged if the value is nil.
  """
  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Format a tool origin for display."
  @spec format_origin(:native | {:upstream, String.t()}) :: String.t()
  def format_origin(:native), do: "native"
  def format_origin({:upstream, prefix}), do: "upstream:#{prefix}"

  @doc """
  Escape SQL LIKE/ILIKE wildcard characters in user input.

  Escapes `%`, `_`, and `\\` so they are treated as literal characters
  rather than pattern wildcards.
  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Parse a human-readable interval string into seconds.

  Supports suffixes: `s` (seconds), `m` (minutes), `h` (hours), `d` (days).
  Returns `{:ok, seconds}` or `:error`.

  ## Examples

      iex> Backplane.Utils.parse_interval("30m")
      {:ok, 1800}

      iex> Backplane.Utils.parse_interval("1h")
      {:ok, 3600}

      iex> Backplane.Utils.parse_interval("2d")
      {:ok, 172800}
  """
  @spec parse_interval(String.t()) :: {:ok, pos_integer()} | :error
  def parse_interval(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, "s"} when n > 0 -> {:ok, n}
      {n, "m"} when n > 0 -> {:ok, n * 60}
      {n, "h"} when n > 0 -> {:ok, n * 3600}
      {n, "d"} when n > 0 -> {:ok, n * 86_400}
      _ -> :error
    end
  end

  def parse_interval(_), do: :error
end
