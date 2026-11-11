defmodule Backplane.Monitor.Providers.DeepSeekTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Providers.DeepSeek

  setup do
    HTTP.Test.verify_on_exit!()

    previous = Application.get_env(:backplane_monitor, :deepseek_http_options)

    Application.put_env(:backplane_monitor, :deepseek_http_options,
      adapter: {HTTP.Test, DeepSeek}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane_monitor, :deepseek_http_options, previous)
      else
        Application.delete_env(:backplane_monitor, :deepseek_http_options)
      end
    end)

    :ok
  end

  test "fetches authenticated currency balances without fabricating usage" do
    HTTP.Test.stub(DeepSeek, fn request ->
      assert request.method == :get
      assert request.url.scheme == "https"
      assert request.url.host == "api.deepseek.com"
      assert request.url.path == "/user/balance"
      assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer private-key"]

      HTTP.Test.json(%{
        is_available: true,
        balance_infos: [balance("CNY"), balance("USD")]
      })
    end)

    assert {:ok, result} = DeepSeek.fetch("private-key")

    assert result == %{
             balances:
               Enum.map(["CNY", "USD"], fn currency ->
                 %{
                   currency: currency,
                   total_balance: "110.00",
                   granted_balance: "10.00",
                   topped_up_balance: "100.00"
                 }
               end),
             usage: [],
             limit: nil,
             is_available: true,
             warnings: []
           }
  end

  test "unavailable accounts, empty balances and absent optional balances remain explicit" do
    HTTP.Test.stub(DeepSeek, fn _request ->
      HTTP.Test.json(%{is_available: false, balance_infos: []})
    end)

    assert {:ok, %{is_available: false, balances: [], usage: []}} = DeepSeek.fetch("key")

    HTTP.Test.stub(DeepSeek, fn _request ->
      HTTP.Test.json(%{
        is_available: false,
        balance_infos: [%{currency: "USD", total_balance: "0.00"}]
      })
    end)

    assert {:ok,
            %{balances: [%{total_balance: "0.00", granted_balance: nil, topped_up_balance: nil}]}} =
             DeepSeek.fetch("key")
  end

  test "rejects malformed shape, currency, availability and decimal fields safely" do
    for body <- [
          %{},
          %{is_available: "true", balance_infos: []},
          %{is_available: true, balance_infos: nil},
          %{is_available: true, balance_infos: [nil]},
          %{is_available: true, balance_infos: [%{currency: "EUR", total_balance: "1"}]},
          %{is_available: true, balance_infos: [%{currency: "USD"}]},
          %{is_available: true, balance_infos: [%{currency: "USD", total_balance: nil}]},
          %{is_available: true, balance_infos: [%{currency: "USD", total_balance: 1}]},
          %{
            is_available: true,
            balance_infos: [%{currency: "USD", total_balance: "1private-key"}]
          },
          %{is_available: true, balance_infos: [%{currency: "USD", total_balance: "NaN"}]},
          %{is_available: true, balance_infos: [%{currency: "USD", total_balance: "Infinity"}]},
          %{is_available: true, balance_infos: [Map.put(balance("USD"), :granted_balance, false)]}
        ] do
      HTTP.Test.stub(DeepSeek, fn _request -> HTTP.Test.json(body) end)
      assert {:error, :invalid_response} = DeepSeek.fetch("private-key")
    end
  end

  test "HTTP, redirects and network errors never disclose secrets" do
    for status <- [302, 401, 500] do
      HTTP.Test.expect(DeepSeek, fn _request ->
        HTTP.Test.response(status, "private-key", [
          {"location", "https://example.com/private-key"}
        ])
      end)

      assert {:error, {:http_error, ^status}} = DeepSeek.fetch("private-key")
    end

    HTTP.Test.expect(DeepSeek, fn _request -> HTTP.Test.transport_error(:timeout) end)
    assert {:error, :request_failed} = DeepSeek.fetch("private-key")
  end

  defp balance(currency) do
    %{
      currency: currency,
      total_balance: "110.00",
      granted_balance: "10.00",
      topped_up_balance: "100.00"
    }
  end
end
