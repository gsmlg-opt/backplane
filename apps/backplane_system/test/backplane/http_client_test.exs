defmodule Backplane.HTTPClientTest do
  use ExUnit.Case, async: true

  alias Backplane.HTTPClient
  alias Backplane.HTTPClient.Error
  alias Backplane.HTTPClient.Proxy
  alias Backplane.HTTPClient.Response

  setup do
    HTTP.Test.verify_on_exit!()
    name = :"http_client_#{System.unique_integer([:positive])}"
    {:ok, name: name, adapter: {HTTP.Test, name}}
  end

  defp header(request, name), do: HTTP.Headers.get(request.headers, name)

  test "encodes JSON, sets headers and auth, and decodes a JSON response", ctx do
    HTTP.Test.expect(ctx.name, fn request ->
      assert request.method in ["POST", :post]
      assert request.url.path == "/v1/items"
      assert request.url.query == "a=1&b=two"
      assert header(request, "content-type") == "application/json"
      assert header(request, "accept") == "application/json"
      assert header(request, "authorization") == "Bearer tok"
      assert header(request, "x-custom") == "yes"
      assert header(request, "user-agent") == "backplane"
      assert Jason.decode!(IO.iodata_to_binary(request.body)) == %{"name" => "n"}
      HTTP.Test.json(%{"ok" => true}, 201)
    end)

    assert {:ok, %Response{status: 201, body: %{"ok" => true}} = response} =
             HTTPClient.post("/v1/items",
               base_url: "https://api.test/",
               params: [a: 1, b: "two"],
               json: %{name: "n"},
               auth: {:bearer, "tok"},
               headers: %{"X-Custom" => "yes"},
               adapter: ctx.adapter
             )

    assert ["application/json" <> _] = Response.get_header(response, "Content-Type")
  end

  test "form bodies, basic auth and undecoded bodies", ctx do
    HTTP.Test.expect(ctx.name, fn request ->
      assert header(request, "content-type") == "application/x-www-form-urlencoded"
      assert header(request, "authorization") == "Basic " <> Base.encode64("id:secret")
      assert IO.iodata_to_binary(request.body) == "grant_type=refresh_token&code=x"
      HTTP.Test.json(%{"access_token" => "t"})
    end)

    assert {:ok, %Response{status: 200, body: body}} =
             HTTPClient.post("https://auth.test/token",
               form: [grant_type: "refresh_token", code: "x"],
               auth: {:basic, "id:secret"},
               decode_body: false,
               adapter: ctx.adapter
             )

    assert Jason.decode!(body) == %{"access_token" => "t"}
  end

  test "rejects conflicting body options without sending", ctx do
    assert {:error, %Error{reason: :conflicting_body_options}} =
             HTTPClient.post("https://api.test", json: %{}, body: "x", adapter: ctx.adapter)
  end

  test "invalid JSON is an error rather than a silent binary", ctx do
    HTTP.Test.stub(ctx.name, fn _ ->
      HTTP.Test.response(200, "{nope", [{"content-type", "application/json"}])
    end)

    assert {:error, %Error{reason: {:invalid_json, _}}} =
             HTTPClient.get("https://api.test", adapter: ctx.adapter)
  end

  test "safe transient retry repeats GET on 503 and honors retry-after", ctx do
    HTTP.Test.expect(ctx.name, 2, fn _ ->
      HTTP.Test.response(503, "busy", [{"retry-after", "0"}])
    end)

    HTTP.Test.expect(ctx.name, fn _ -> HTTP.Test.text("ok") end)

    assert {:ok, %Response{status: 200, body: "ok"}} =
             HTTPClient.get("https://api.test", adapter: ctx.adapter)
  end

  test "transport errors retry for GET and stop at max_retries", ctx do
    HTTP.Test.expect(ctx.name, 3, fn _ -> HTTP.Test.transport_error(:econnrefused) end)

    assert {:error, %Error{reason: :econnrefused}} =
             HTTPClient.get("https://api.test",
               adapter: ctx.adapter,
               max_retries: 2,
               retry_delay: 0
             )
  end

  test "POST is not retried by default and retry: false disables retries", ctx do
    HTTP.Test.expect(ctx.name, fn _ -> HTTP.Test.status(503) end)

    assert {:ok, %Response{status: 503}} =
             HTTPClient.post("https://api.test", body: "x", adapter: ctx.adapter)

    HTTP.Test.expect(ctx.name, fn _ -> HTTP.Test.status(503) end)

    assert {:ok, %Response{status: 503}} =
             HTTPClient.get("https://api.test", retry: false, adapter: ctx.adapter)
  end

  test "into streams chunks to a function and halts early", ctx do
    HTTP.Test.stub(ctx.name, fn _ -> HTTP.Test.stream(["ab", "cd", "ef"]) end)

    into = fn {:data, chunk}, acc ->
      acc = acc <> chunk
      if byte_size(acc) >= 4, do: {:halt, acc}, else: {:cont, acc}
    end

    assert {:ok, %Response{status: 200, body: "abcd"}} =
             HTTPClient.get("https://api.test", into: into, into_acc: "", adapter: ctx.adapter)
  end

  test "into collects a streamed body into a file", ctx do
    path = Path.join(System.tmp_dir!(), "http_client_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    HTTP.Test.stub(ctx.name, fn _ -> HTTP.Test.stream(["hello ", "world"]) end)

    assert {:ok, %Response{status: 200}} =
             HTTPClient.get("https://api.test", into: File.stream!(path), adapter: ctx.adapter)

    assert File.read!(path) == "hello world"
  end

  test "max_body_bytes rejects oversized buffered and streamed bodies", ctx do
    HTTP.Test.expect(ctx.name, fn _ -> HTTP.Test.text("too large") end)
    HTTP.Test.expect(ctx.name, fn _ -> HTTP.Test.stream(["12345", "6789"]) end)

    for _ <- 1..2 do
      assert {:error, %Error{reason: :response_too_large}} =
               HTTPClient.get("https://api.test",
                 max_body_bytes: 6,
                 retry: false,
                 adapter: ctx.adapter
               )
    end
  end

  test "bang functions raise the error", ctx do
    HTTP.Test.expect(ctx.name, fn _ -> HTTP.Test.transport_error(:closed) end)

    assert_raise Error, ~r/:closed/, fn ->
      HTTPClient.post!("https://api.test", body: "x", adapter: ctx.adapter)
    end
  end

  describe "Proxy.from_env/1" do
    setup do
      keys =
        ~w(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy)

      saved = Map.new(keys, &{&1, System.get_env(&1)})
      Enum.each(keys, &System.delete_env/1)

      on_exit(fn ->
        Enum.each(saved, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end)
    end

    test "builds an authenticated proxy and honors NO_PROXY" do
      System.put_env("HTTPS_PROXY", "http://user:pw@proxy.test:3128")
      System.put_env("NO_PROXY", ".internal")

      assert {:http, "proxy.test", 3128, [headers: [{"proxy-authorization", auth}]]} =
               Proxy.from_env("https://api.example.com/x")

      assert auth == "Basic " <> Base.encode64("user:pw")
      assert Proxy.from_env("https://svc.internal/x") == nil
      assert Proxy.from_env("http://api.example.com") == nil
    end
  end
end
