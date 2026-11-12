defmodule Backplane.Oauth.HttpClientTest do
  use ExUnit.Case, async: false

  alias Backplane.Oauth.HttpClient

  setup do
    previous = Application.fetch_env!(:backplane_oauth, Backplane.Oauth)
    on_exit(fn -> Application.put_env(:backplane_oauth, Backplane.Oauth, previous) end)

    Application.put_env(
      :backplane_oauth,
      Backplane.Oauth,
      previous
      |> Keyword.put(:issuer, "not a url")
      |> Keyword.put(:http_adapter, {HTTP.Test, :oauth_http})
    )

    HTTP.Test.verify_on_exit!()
    :ok
  end

  test "fetches trusted HTTPS URLs with system CAs, the full URL and no redirect following" do
    test_pid = self()

    HTTP.Test.expect(:oauth_http, fn request ->
      send(test_pid, {:request, request})
      HTTP.Test.text(~s({"keys":[]}))
    end)

    assert {:ok, %{status: 200, body: ~s({"keys":[]}), headers: headers}} =
             HttpClient.get("https://idp.example.test/jwks?kid=1", "", ["idp.example.test"])

    assert is_list(headers)
    assert_received {:request, request}
    assert URI.to_string(request.url) == "https://idp.example.test/jwks?kid=1"
    assert request.method == :get
    assert request.transport_options[:ssl][:cacerts] == :public_key.cacerts_get()
  end

  test "pins trusted authorities as the only CA certificates" do
    [{:cert, der, _otp} | _] = :public_key.cacerts_get()
    pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    test_pid = self()

    HTTP.Test.expect(:oauth_http, fn request ->
      send(test_pid, {:cacerts, request.transport_options[:ssl][:cacerts]})
      HTTP.Test.status(302) |> HTTP.Test.headers([{"location", "https://elsewhere.test/"}])
    end)

    assert {:ok, %{status: 302}} =
             HttpClient.get("https://idp.example.test/request", pem, ["idp.example.test"])

    assert_received {:cacerts, [^der]}
  end

  test "maps TLS alerts to an untrusted certificate error" do
    HTTP.Test.expect(:oauth_http, fn _request ->
      HTTP.Test.transport_error({:tls_alert, {:unknown_ca, ~c"unknown ca"}})
    end)

    assert {:error, "Host certificate is not trusted."} =
             HttpClient.get("https://idp.example.test/jwks", "", ["idp.example.test"])
  end

  test "rejects plain HTTP and untrusted or invalid inputs without a request" do
    assert {:error, "Certificate pinning requires HTTPS."} =
             HttpClient.get("http://idp.example.test/jwks", "", ["idp.example.test"])

    assert {:error, "Host is not trusted for outbound requests."} =
             HttpClient.get("https://other.example.test/jwks", "", ["idp.example.test"])

    assert {:error, "Trusted authorities must contain PEM certificates."} =
             HttpClient.get("https://idp.example.test/jwks", "not a pem", [])

    assert {:error, "Client must configure trusted hosts or authorities for outbound requests."} =
             HttpClient.get("https://idp.example.test/jwks")
  end
end
