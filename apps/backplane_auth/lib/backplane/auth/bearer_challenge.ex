defmodule Backplane.Auth.BearerChallenge do
  @moduledoc """
  Serializes the Bearer challenge shared by Backplane's protected resources.
  """

  alias Backplane.Auth.{OAuth, Resources}

  @spec put(Plug.Conn.t(), Resources.key(), keyword()) :: Plug.Conn.t()
  def put(conn, resource, opts \\ []) do
    params =
      []
      |> maybe_add("error", opts[:error])
      |> maybe_add("scope", opts[:scope])
      |> maybe_add_resource_metadata(conn, resource)

    value =
      case params do
        [] ->
          "Bearer"

        values ->
          "Bearer " <>
            Enum.map_join(values, ", ", fn {key, value} ->
              ~s(#{key}="#{escape(value)}")
            end)
      end

    Plug.Conn.put_resp_header(conn, "www-authenticate", value)
  end

  defp maybe_add(params, _key, nil), do: params
  defp maybe_add(params, key, value), do: params ++ [{key, to_string(value)}]

  defp maybe_add_resource_metadata(params, conn, resource) do
    if OAuth.enabled_client_for_resource?(resource) and
         conn.request_path == Resources.path(resource) and
         conn.query_string == "" do
      params ++ [{"resource_metadata", Resources.metadata_uri(resource)}]
    else
      params
    end
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
