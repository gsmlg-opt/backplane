defmodule Backplane.Api.Auth.ResourceParams do
  @moduledoc false

  alias Backplane.Auth.Resources

  @spec query(Plug.Conn.t(), map()) ::
          {:ok, nil | Resources.key()} | {:error, :invalid_target}
  def query(conn, params) do
    with {:ok, values} <- resource_values(URI.query_decoder(conn.query_string)) do
      normalize(values, params["resource"])
    end
  rescue
    ArgumentError -> {:error, :invalid_target}
  end

  @spec structured_query_parameter?(Plug.Conn.t(), String.t()) :: boolean()
  def structured_query_parameter?(conn, name) do
    Enum.any?(URI.query_decoder(conn.query_string), fn {key, _value} ->
      structured_key?(key, name)
    end)
  rescue
    ArgumentError -> true
  end

  @spec form(Plug.Conn.t(), map()) ::
          {:ok, nil | Resources.key()} | {:error, :invalid_target}
  def form(%Plug.Conn{private: %{oauth_form_pairs: :malformed}}, _params),
    do: {:error, :invalid_target}

  def form(%Plug.Conn{private: %{oauth_form_pairs: pairs}, body_params: body_params}, _params)
      when is_list(pairs) and is_map(body_params) do
    with {:ok, values} <- resource_values(pairs) do
      normalize(values, body_params["resource"])
    end
  end

  def form(_conn, _params), do: {:ok, nil}

  defp normalize([], nil), do: {:ok, nil}
  defp normalize([], parsed) when is_binary(parsed), do: normalize([parsed], parsed)

  defp normalize([value], parsed)
       when is_binary(value) and (is_nil(parsed) or parsed == value),
       do: value |> Resources.from_uri() |> normalize_uri()

  defp normalize(_repeated_or_structured, _parsed), do: {:error, :invalid_target}

  defp resource_values(pairs) do
    if Enum.any?(pairs, fn {key, _value} -> structured_key?(key, "resource") end) do
      {:error, :invalid_target}
    else
      values =
        pairs
        |> Enum.filter(fn {key, _value} -> key == "resource" end)
        |> Enum.map(&elem(&1, 1))

      {:ok, values}
    end
  end

  defp structured_key?(key, name),
    do: is_binary(key) and String.starts_with?(key, name <> "[")

  defp normalize_uri({:ok, resource}), do: {:ok, resource}
  defp normalize_uri(:error), do: {:error, :invalid_target}
end
