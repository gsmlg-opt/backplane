defmodule Backplane.Monitor.Providers.OpenRouterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.Monitor.Providers.OpenRouter

  defmodule RaisingAdapter do
    @behaviour HTTP.Adapter
    def prepare(_request, _options), do: raise("private-key")
    def execute(_request, _context, _signal), do: raise("private-key")
  end

  setup do
    HTTP.Test.verify_on_exit!()
    previous = Application.get_env(:backplane_monitor, :openrouter_http_options)

    Application.put_env(:backplane_monitor, :openrouter_http_options,
      adapter: {HTTP.Test, OpenRouter}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane_monitor, :openrouter_http_options, previous)
      else
        Application.delete_env(:backplane_monitor, :openrouter_http_options)
      end
    end)

    :ok
  end

  test "fetches authenticated key usage and limits without exposing key metadata" do
    HTTP.Test.stub(OpenRouter, fn request ->
      assert request.method == :get
      assert request.url.scheme == "https"
      assert request.url.host == "openrouter.ai"
      assert request.url.path == "/api/v1/key"
      assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer private-key"]

      HTTP.Test.json(%{
        data: %{
          label: "private-key",
          limit: 100,
          limit_remaining: 98.75,
          limit_reset: "monthly",
          usage: 1.25,
          usage_daily: 0.25,
          usage_weekly: 1,
          usage_monthly: 1.25,
          is_management_key: false
        }
      })
    end)

    assert {:ok, result} = OpenRouter.fetch("private-key")
    assert result.balances == []
    assert result.is_available == nil
    assert result.warnings == []
    assert result.limit == %{amount: "100", remaining: "98.75", currency: "USD", reset: "monthly"}

    assert result.usage == [
             %{label: "Key usage (all time)", amount: "1.25", currency: "USD"},
             %{label: "Key usage (daily)", amount: "0.25", currency: "USD"},
             %{label: "Key usage (weekly)", amount: "1", currency: "USD"},
             %{label: "Key usage (monthly)", amount: "1.25", currency: "USD"}
           ]

    refute inspect(result) =~ "private-key"
  end

  test "optional management credits use their own key and exact decimal subtraction" do
    HTTP.Test.stub(OpenRouter, fn request ->
      case request.url.path do
        "/api/v1/key" ->
          assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer key"]

          HTTP.Test.json(%{
            data: %{usage: 0, limit: nil, limit_remaining: nil, limit_reset: nil}
          })

        "/api/v1/credits" ->
          assert request.url.host == "openrouter.ai"
          assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer management"]
          HTTP.Test.json(%{data: %{total_credits: 0.3, total_usage: 0.1}})
      end
    end)

    assert {:ok, result} = OpenRouter.fetch("key", "management")
    assert result.limit == nil

    assert result.balances == [
             %{
               currency: "USD",
               total_balance: "0.2",
               granted_balance: nil,
               topped_up_balance: "0.3"
             }
           ]

    assert List.last(result.usage) == %{
             label: "Account usage (all time)",
             amount: "0.1",
             currency: "USD"
           }
  end

  test "missing and null fields stay unavailable, never fabricated as zero" do
    HTTP.Test.stub(OpenRouter, fn _request ->
      HTTP.Test.json(%{data: %{limit: nil, usage_daily: nil}})
    end)

    assert {:ok, %{balances: [], usage: [], limit: nil}} = OpenRouter.fetch("key")
  end

  test "scientific notation and oversized integer account credits subtract exactly" do
    trillion_trillions = "1" <> String.duplicate("0", 35)

    for {credits, usage, expected} <- [
          {"1e35", "0", trillion_trillions},
          {"1e35", "1", String.duplicate("9", 35)},
          {"100000000000000000000000000000000001", "1", trillion_trillions}
        ] do
      HTTP.Test.stub(OpenRouter, fn request ->
        if request.url.path == "/api/v1/key" do
          HTTP.Test.json(%{data: %{usage: 1}})
        else
          json_bytes(~s({"data":{"total_credits":#{credits},"total_usage":#{usage}}}))
        end
      end)

      assert {:ok, result} = OpenRouter.fetch("private-key", "management-secret")
      assert [%{total_balance: ^expected}] = result.balances
      assert result.warnings == []
      assert hd(result.usage) == %{label: "Key usage (all time)", amount: "1", currency: "USD"}
    end
  end

  test "optional account arithmetic overflow preserves key success with a safe warning" do
    HTTP.Test.stub(OpenRouter, fn request ->
      if request.url.path == "/api/v1/key" do
        HTTP.Test.json(%{data: %{usage: 1}})
      else
        json_bytes(~s({"data":{"total_credits":9e6144,"total_usage":-9e6144}}))
      end
    end)

    assert {:ok, result} = OpenRouter.fetch("private-key", "management-secret")
    assert result.balances == []
    assert result.usage == [%{label: "Key usage (all time)", amount: "1", currency: "USD"}]
    assert result.warnings == [{:account_credits, :invalid_response}]
    refute inspect(result) =~ "private-key"
    refute inspect(result) =~ "management-secret"
  end

  test "only documented reset values and nil are accepted" do
    for reset <- [nil, "daily", "weekly", "monthly"] do
      HTTP.Test.stub(OpenRouter, fn _request ->
        HTTP.Test.json(%{data: %{limit: 10, limit_reset: reset}})
      end)

      assert {:ok, %{limit: %{reset: ^reset}}} = OpenRouter.fetch("private-key")
    end
  end

  test "unexpected or secret-bearing resets never enter a snapshot or error" do
    for reset <- ["private-key", "monthly private-key", "", "yearly"] do
      HTTP.Test.stub(OpenRouter, fn _request ->
        HTTP.Test.json(%{data: %{usage: 1, limit_reset: reset}})
      end)

      assert {:error, :invalid_response} = result = OpenRouter.fetch("private-key")
      refute inspect(result) =~ "private-key"
    end
  end

  test "malformed key responses produce only safe errors" do
    for data <- [%{usage: "private-key"}, %{usage: false}, %{limit: []}, %{limit_reset: 42}] do
      HTTP.Test.stub(OpenRouter, fn _request -> HTTP.Test.json(%{data: data}) end)
      assert {:error, :invalid_response} = OpenRouter.fetch("private-key")
    end

    for body <- [%{}, %{data: []}, %{data: nil}] do
      HTTP.Test.stub(OpenRouter, fn _request -> HTTP.Test.json(body) end)
      assert {:error, :invalid_response} = OpenRouter.fetch("key")
    end
  end

  test "optional credit HTTP, network and parsing failures preserve successful key usage" do
    for failure <- [:http, :network, :malformed, :missing] do
      HTTP.Test.stub(OpenRouter, fn request ->
        if request.url.path == "/api/v1/key" do
          HTTP.Test.json(%{data: %{usage: 1}})
        else
          case failure do
            :http ->
              HTTP.Test.response(403, "management-secret")

            :network ->
              HTTP.Test.transport_error(:timeout)

            :malformed ->
              HTTP.Test.json(%{data: %{total_credits: "management-secret", total_usage: 0}})

            :missing ->
              HTTP.Test.json(%{data: %{total_credits: 10}})
          end
        end
      end)

      assert {:ok, result} = OpenRouter.fetch("key", "management-secret")
      assert result.balances == []
      assert result.usage == [%{label: "Key usage (all time)", amount: "1", currency: "USD"}]
      assert [{:account_credits, _reason}] = result.warnings
      refute inspect(result) =~ "management-secret"
    end
  end

  test "HTTP errors and redirects never return response bodies or follow locations" do
    for status <- [301, 302, 307, 308, 401, 429, 500] do
      HTTP.Test.expect(OpenRouter, fn request ->
        assert request.url.host == "openrouter.ai"

        HTTP.Test.response(status, "private-key", [
          {"location", "https://example.com/private-key"}
        ])
      end)

      assert {:error, {:http_error, ^status}} = OpenRouter.fetch("private-key")
    end
  end

  test "network and malformed JSON errors are redacted and not logged" do
    log =
      capture_log(fn ->
        HTTP.Test.expect(OpenRouter, fn _request -> HTTP.Test.transport_error(:timeout) end)
        assert {:error, :request_failed} = OpenRouter.fetch("private-key")

        HTTP.Test.expect(OpenRouter, fn _request -> json_bytes("private-key") end)

        assert {:error, :invalid_response} = OpenRouter.fetch("private-key")
      end)

    refute log =~ "private-key"
  end

  test "request options enforce fixed endpoints, bounded timeouts and disabled logging" do
    clear_proxy_env()

    test_pid = self()

    Application.put_env(:backplane_monitor, :openrouter_http_options,
      adapter: {HTTP.Test, OpenRouter},
      url: "https://example.com",
      auth: {:bearer, "wrong-key"},
      redirect: true,
      retry: true,
      receive_timeout: :infinity
    )

    HTTP.Test.stub(OpenRouter, fn request ->
      send(test_pid, {:request, request})
      HTTP.Test.json(%{data: %{usage: 1}})
    end)

    assert {:ok, _result} = OpenRouter.fetch("key")
    assert_receive {:request, request}
    assert request.method == :get
    assert URI.to_string(request.url) == "https://openrouter.ai/api/v1/key"
    assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer key"]

    transport = request.transport_options
    assert transport[:redirect] == :manual
    assert transport[:timeout] == 15_000
    assert transport[:connect_timeout] == 5_000
    refute Keyword.has_key?(transport, :proxy)

    System.put_env("HTTPS_PROXY", "http://10.0.0.1:3128")
    assert {:ok, _result} = OpenRouter.fetch("key")
    assert_receive {:request, request}
    assert request.transport_options[:proxy] == {:http, "10.0.0.1", 3128, []}
  end

  defp json_bytes(body), do: HTTP.Test.response(200, body, [{"content-type", "application/json"}])

  @proxy_vars ~w(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy)

  defp clear_proxy_env do
    saved = Map.new(@proxy_vars, &{&1, System.get_env(&1)})
    Enum.each(@proxy_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "adapter exceptions containing secrets are returned as safe request failures" do
    Application.put_env(:backplane_monitor, :openrouter_http_options, adapter: RaisingAdapter)

    log =
      capture_log(fn ->
        assert {:error, :request_failed} = OpenRouter.fetch("private-key")
      end)

    refute log =~ "private-key"
  end
end
