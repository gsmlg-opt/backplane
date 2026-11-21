defmodule Backplane.Oauth.ValidatorTest do
  use ExUnit.Case, async: true

  alias Backplane.Oauth.Validator

  @client_id "4ef74d51-3d56-41a1-b16c-d57435edee24"

  test "validates token parameters without removing optional or extension values" do
    params = %{
      "grant_type" => "client_credentials",
      "client_id" => @client_id,
      "client_authentication" => %{"type" => "post", "value" => nil},
      "extension" => %{"enabled" => true}
    }

    assert {:ok, ^params} = Validator.validate(:token, params)
  end

  test "reports missing properties at the root" do
    assert {:error,
            "Request body validation failed. Required properties client_id, client_authentication are missing at #."} =
             Validator.validate(:token, %{"grant_type" => "client_credentials"})
  end

  test "reports nested pattern and type errors without echoing request values" do
    params = %{
      "client_id" => @client_id,
      "client_authentication" => %{"type" => "private-input", "value" => false},
      "token" => "private-token"
    }

    assert {:error, description} = Validator.validate(:introspect, params)

    assert description ==
             "Request validation failed. #/client_authentication/type do match required pattern /^(basic|post|jwt)$/. " <>
               "The type at #/client_authentication/value `boolean` do not match the required types [\"string\", \"null\"]."
  end

  test "validates every response type in a hybrid authorization request" do
    params = %{
      "response_type" => "code id_token token",
      "client_id" => @client_id,
      "redirect_uri" => "https://example.test/callback"
    }

    assert {:ok, ^params} = Validator.validate(:authorize, params)

    assert {:error, "Query params validation failed. " <> _} =
             Validator.validate(:authorize, Map.put(params, "response_mode", "unsupported"))
  end
end
