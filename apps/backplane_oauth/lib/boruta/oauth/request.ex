# credo:disable-for-this-file Credo.Check.Warning.SpecWithStruct
defmodule Boruta.Oauth.Request do
  @moduledoc """
  Build an oauth request struct from given input.

  > __Note__: Input must have the shape or be a `%Plug.Conn{}` request.
  """

  alias Boruta.Oauth.Request

  @doc """
  Create request struct from an OAuth token request.

  ## Examples
      iex>token_request(%{
        body_params: %{
          "grant_type" => "client_credentials",
          "client_id" => "client_id",
          "client_secret" => "client_secret"
        }
      })
      {:ok, %ClientCredentialsRequest{...}}
  """
  @spec token_request(
          conn ::
            Plug.Conn.t()
            | %{
                optional(:req_headers) => list(),
                body_params: map()
              }
        ) ::
          {:error,
           %Boruta.Oauth.Error{
             :error => :invalid_request,
             :error_description => String.t(),
             :format => nil,
             :redirect_uri => nil,
             :status => :bad_request
           }}
          | {:ok,
             oauth_request ::
               Boruta.Oauth.AuthorizationCodeRequest.t()
               | Boruta.Oauth.ClientCredentialsRequest.t()
               | Boruta.Oauth.AuthorizationCodeRequest.t()
               | Boruta.Oauth.TokenRequest.t()
               | Boruta.Oauth.PasswordRequest.t()}
  defdelegate token_request(conn), to: Request.Token, as: :request

  @doc """
  Create request struct from an OAuth authorize request.

  Note : resource owner must be provided as current_user assigns.

  ## Examples
      iex>authorize_request(
        %{
          query_params: %{
            "response_type" => "token",
            "client_id" => "client_id",
            "redirect_uri" => "redirect_uri"
          },
        },
        %User{...}
      )
      {:ok, %TokenRequest{...}}
  """
  @spec authorize_request(
          conn :: Plug.Conn.t() | %{body_params: map()},
          resource_owner :: struct
        ) ::
          {:error,
           %Boruta.Oauth.Error{
             :error => :invalid_request,
             :error_description => String.t(),
             :format => nil,
             :redirect_uri => nil,
             :status => :bad_request
           }}
          | {:ok,
             oauth_request ::
               Boruta.Oauth.CodeRequest.t()
               | Boruta.Oauth.TokenRequest.t()
               | Boruta.Oauth.HybridRequest.t()}
  defdelegate authorize_request(conn, resource_owner), to: Request.Authorize, as: :request

  @doc """
  Create request struct from an OAuth introspect request.

  ## Examples
      iex>introspect_request(%{
        body_params: %{
          "token" => "token",
          "client_id" => "client_id",
          "client_secret" => "client_secret",
        }
      })
      {:ok, %IntrospectRequest{...}}
  """
  @spec introspect_request(
          conn ::
            Plug.Conn.t()
            | %{
                optional(:req_headers) => list(),
                body_params: map()
              }
        ) ::
          {:error,
           %Boruta.Oauth.Error{
             :error => :invalid_request,
             :error_description => String.t(),
             :format => nil,
             :redirect_uri => nil,
             :status => :bad_request
           }}
          | {:ok, request :: Boruta.Oauth.IntrospectRequest.t()}
  defdelegate introspect_request(conn), to: Request.Introspect, as: :request

  @doc """
  Create request struct from an OAuth revoke request.

  ## Examples
      iex>revoke_request(%{
        body_params: %{
          "token" => "token",
          "client_id" => "client_id",
          "client_secret" => "client_secret",
        }
      })
      {:ok, %RevokeRequest{...}}
  """
  @spec revoke_request(
          conn ::
            Plug.Conn.t()
            | %{
                optional(:req_headers) => list(),
                body_params: map()
              }
        ) ::
          {:error,
           %Boruta.Oauth.Error{
             :error => :invalid_request,
             :error_description => String.t(),
             :format => nil,
             :redirect_uri => nil,
             :status => :bad_request
           }}
          | {:ok, request :: Boruta.Oauth.RevokeRequest.t()}
  defdelegate revoke_request(conn), to: Request.Revoke, as: :request
end
