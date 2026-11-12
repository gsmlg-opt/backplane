defprotocol Backplane.Oauth.Authorization.Nonce do
  @moduledoc """
  Check OpenID Connect nonce against given request
  """

  @doc """
  Authorize the given request corresponding the nonce value.

  ## Examples
      iex> authorize(%CodeRequest{...})
      :ok
  """
  @spec authorize(request :: Backplane.Oauth.CodeRequest.t() | Backplane.Oauth.TokenRequest.t()) ::
          :ok | {:error, Backplane.Oauth.Error.t()}
  def authorize(request)
end

defimpl Backplane.Oauth.Authorization.Nonce, for: Backplane.Oauth.CodeRequest do
  alias Backplane.Oauth.CodeRequest
  alias Backplane.Oauth.Error

  def authorize(%Backplane.Oauth.CodeRequest{nonce: nonce} = request) do
    case {CodeRequest.require_nonce?(request), nonce} do
      {true, nonce} when nonce in [nil, ""] ->
        {:error,
         %Error{
           status: :bad_request,
           error: :invalid_request,
           error_description: "OpenID requests require a nonce."
         }}

      _ ->
        :ok
    end
  end
end

defimpl Backplane.Oauth.Authorization.Nonce, for: Backplane.Oauth.TokenRequest do
  alias Backplane.Oauth.Error
  alias Backplane.Oauth.TokenRequest

  def authorize(%Backplane.Oauth.TokenRequest{nonce: nonce} = request) do
    case {TokenRequest.require_nonce?(request), nonce} do
      {true, nonce} when nonce in [nil, ""] ->
        {:error,
         %Error{
           status: :bad_request,
           error: :invalid_request,
           error_description: "OpenID requests require a nonce."
         }}

      _ ->
        :ok
    end
  end
end
