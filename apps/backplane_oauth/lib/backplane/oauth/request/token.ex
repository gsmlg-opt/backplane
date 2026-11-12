# credo:disable-for-this-file Credo.Check.Warning.SpecWithStruct
defmodule Backplane.Oauth.Request.Token do
  @moduledoc false

  import Backplane.Oauth.Request.Base

  alias Backplane.Oauth.ClientsAdapter
  alias Backplane.Oauth.AuthorizationCodeRequest
  alias Backplane.Oauth.ClientCredentialsRequest
  alias Backplane.Oauth.Error
  alias Backplane.Oauth.PasswordRequest
  alias Backplane.Oauth.Validator

  @spec request(conn :: Plug.Conn.t() | map()) ::
          {:error,
           %Error{
             :error => :invalid_request,
             :error_description => String.t(),
             :format => nil,
             :redirect_uri => nil,
             :status => :bad_request
           }}
          | {:ok,
             oauth_request ::
               AuthorizationCodeRequest.t()
               | ClientCredentialsRequest.t()
               | PasswordRequest.t()}
  def request(%{body_params: body_params} = request) do
    with client <- ClientsAdapter.get_client(body_params["client_id"]),
         {:ok, unsigned_params} <- fetch_unsigned_request(request, client),
         {:ok, client_authentication_params} <- fetch_client_authentication(request),
         {:ok, params} <-
           Validator.validate(
             :token,
             body_params
             |> Enum.into(unsigned_params)
             |> Enum.into(client_authentication_params)
           ) do
      build_request(params)
    else
      {:error, error_description} ->
        {:error,
         %Error{
           status: :bad_request,
           error: :invalid_request,
           error_description: error_description
         }}
    end
  end
end
