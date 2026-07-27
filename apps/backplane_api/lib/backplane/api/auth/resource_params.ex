defmodule Backplane.Api.Auth.ResourceParams do
  @moduledoc false

  alias Backplane.Auth.Resources

  @spec query(Plug.Conn.t(), map()) ::
          {:ok, nil | Resources.key()} | {:error, :invalid_target}
  def query(conn, params) do
    values =
      conn.query_string
      |> URI.query_decoder()
      |> Enum.filter(fn {key, _value} -> key == "resource" end)
      |> Enum.map(&elem(&1, 1))

    normalize(values, params["resource"])
  rescue
    ArgumentError -> {:error, :invalid_target}
  end

  @spec form(Plug.Conn.t(), map()) ::
          {:ok, nil | Resources.key()} | {:error, :invalid_target}
  def form(%Plug.Conn{private: %{oauth_form_pairs: :malformed}}, _params),
    do: {:error, :invalid_target}

  def form(%Plug.Conn{private: %{oauth_form_pairs: pairs}, body_params: body_params}, _params)
      when is_list(pairs) and is_map(body_params) do
    values =
      pairs
      |> Enum.filter(fn {key, _value} -> key == "resource" end)
      |> Enum.map(&elem(&1, 1))

    normalize(values, body_params["resource"])
  end

  def form(_conn, _params), do: {:ok, nil}

  defp normalize([], nil), do: {:ok, nil}
  defp normalize([], parsed), do: normalize([parsed], nil)

  defp normalize([value], _parsed) when is_binary(value),
    do: value |> Resources.from_uri() |> normalize_uri()

  defp normalize(_repeated_or_structured, _parsed), do: {:error, :invalid_target}

  defp normalize_uri({:ok, resource}), do: {:ok, resource}
  defp normalize_uri(:error), do: {:error, :invalid_target}
end
