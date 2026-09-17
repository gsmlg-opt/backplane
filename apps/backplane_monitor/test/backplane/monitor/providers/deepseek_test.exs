defmodule Backplane.Monitor.Providers.DeepSeekTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Providers.DeepSeek

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:req)
    :ok
  end

  setup do
    previous = Application.get_env(:backplane_monitor, :deepseek_req_options)
    Application.put_env(:backplane_monitor, :deepseek_req_options, plug: {Req.Test, DeepSeek})

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane_monitor, :deepseek_req_options, previous)
      else
        Application.delete_env(:backplane_monitor, :deepseek_req_options)
      end
    end)

    :ok
  end

  test "fetches authenticated currency balances without fabricating usage" do
    Req.Test.stub(DeepSeek, fn conn ->
      assert conn.method == "GET"
      assert conn.scheme == :https
      assert conn.host == "api.deepseek.com"
      assert conn.request_path == "/user/balance"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer private-key"]

      Req.Test.json(conn, %{
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
    Req.Test.stub(DeepSeek, &Req.Test.json(&1, %{is_available: false, balance_infos: []}))
    assert {:ok, %{is_available: false, balances: [], usage: []}} = DeepSeek.fetch("key")

    Req.Test.stub(
      DeepSeek,
      &Req.Test.json(&1, %{
        is_available: false,
        balance_infos: [%{currency: "USD", total_balance: "0.00"}]
      })
    )

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
      Req.Test.stub(DeepSeek, &Req.Test.json(&1, body))
      assert {:error, :invalid_response} = DeepSeek.fetch("private-key")
    end
  end

  test "HTTP, redirects and network errors never disclose secrets" do
    for status <- [302, 401, 500] do
      Req.Test.expect(DeepSeek, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://example.com/private-key")
        |> Plug.Conn.send_resp(status, "private-key")
      end)

      assert {:error, {:http_error, ^status}} = DeepSeek.fetch("private-key")
    end

    Req.Test.stub(DeepSeek, &Req.Test.transport_error(&1, :timeout))
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
