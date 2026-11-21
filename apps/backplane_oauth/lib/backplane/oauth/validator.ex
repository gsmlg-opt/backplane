defmodule Backplane.Oauth.Validator do
  @moduledoc """
  Utility to validate the request according to the given parameters
  """

  # TODO find a way to difference query from body params
  alias Backplane.Oauth.Json.Schema
  alias Backplane.Oauth.JsonSchemaErrorFormatter

  @doc """
  Validates given OAuth parameters.
  ## Examples
      iex> validate(:token, %{
        "grant_type" => "client_credentials",
        "client_id" => "client_id",
        "client_secret" => "client_secret"
      })
      {:ok, %{
        "grant_type" => "client_credentials",
        "client_id" => "client_id",
        "client_secret" => "client_secret"
      }}

      iex> validate(:authorize, %{})
      {:error, "Request is not a valid OAuth request. Need a response_type param."}
  """
  @spec validate(action :: :token | :authorize | :introspect | :revoke, params :: map()) ::
          {:ok, params :: map()} | {:error, message :: String.t()}
  def validate(:token, %{"grant_type" => grant_type} = params)
      when grant_type in ["password", "client_credentials", "authorization_code", "refresh_token"] do
    params
    |> Formata.validate(apply(Schema, String.to_atom(grant_type), []))
    |> validation_result(params, "Request body validation failed.")
  end

  def validate(:token, %{"grant_type" => _} = params) do
    case Formata.validate(params, Schema.grant_type()) do
      :ok -> {:error, "Request body validation failed. Invalid grant_type."}
      {:error, errors} -> validation_error(errors, "Request body validation failed.")
    end
  end

  def validate(:authorize, %{"response_type" => response_types} = params)
      when response_types in [
             "token",
             "id_token",
             "id_token token",
             "code",
             "code id_token",
             "code token",
             "code id_token token"
           ] do
    params
    |> validate_multiple_response_types()
    |> validation_result(params, "Query params validation failed.")
  end

  def validate(:authorize, %{"response_type" => _}) do
    {:error,
     "Invalid response_type param, may be on of `code` for Authorization Code request, `code id_token`, `code token`, `code id_token token` for Hybrid requests, or `token`, `id_token token` for Implicit requests."}
  end

  def validate(:introspect, params) do
    params
    |> Formata.validate(Schema.introspect())
    |> validation_result(params, "Request validation failed.")
  end

  def validate(:revoke, params) do
    params
    |> Formata.validate(Schema.revoke())
    |> validation_result(params, "Request validation failed.")
  end

  def validate(:token, _params) do
    {:error, "Request is not a valid OAuth request. Need a grant_type param."}
  end

  def validate(:authorize, _params) do
    {:error, "Request is not a valid OAuth request. Need a response_type param."}
  end

  defp validate_multiple_response_types(%{"response_type" => response_types} = params) do
    response_types
    |> String.split(" ")
    |> Enum.reduce_while(:ok, fn response_type, _acc ->
      case Formata.validate(params, apply(Schema, String.to_atom(response_type), [])) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
  end

  defp validation_result(:ok, params, _prefix), do: {:ok, params}
  defp validation_result({:error, errors}, _params, prefix), do: validation_error(errors, prefix)

  defp validation_error(errors, prefix) do
    description = errors |> JsonSchemaErrorFormatter.format() |> Enum.join(" ")
    {:error, prefix <> " " <> description}
  end
end
