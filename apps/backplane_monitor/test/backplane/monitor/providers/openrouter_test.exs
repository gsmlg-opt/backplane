defmodule Backplane.Monitor.Providers.OpenRouterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.Monitor.Providers.OpenRouter

  defmodule InspectingAdapter do
    def run(request) do
      send(self(), {:request, request})
      {request, Req.Response.new(status: 200, body: Jason.encode!(%{data: %{usage: 1}}))}
    end
  end

  defmodule RaisingAdapter do
    def run(_request), do: raise("private-key")
  end

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:req)
    :ok
  end

  setup do
    previous = Application.get_env(:backplane_monitor, :openrouter_req_options)
    Application.put_env(:backplane_monitor, :openrouter_req_options, plug: {Req.Test, OpenRouter})

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane_monitor, :openrouter_req_options, previous)
      else
        Application.delete_env(:backplane_monitor, :openrouter_req_options)
      end
    end)

    :ok
  end

  test "fetches authenticated key usage and limits without exposing key metadata" do
    Req.Test.stub(OpenRouter, fn conn ->
      assert conn.method == "GET"
      assert conn.scheme == :https
      assert conn.host == "openrouter.ai"
      assert conn.request_path == "/api/v1/key"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer private-key"]

      Req.Test.json(conn, %{
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
    Req.Test.stub(OpenRouter, fn conn ->
      case conn.request_path do
        "/api/v1/key" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer key"]

          Req.Test.json(conn, %{
            data: %{usage: 0, limit: nil, limit_remaining: nil, limit_reset: nil}
          })

        "/api/v1/credits" ->
          assert conn.host == "openrouter.ai"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer management"]
          Req.Test.json(conn, %{data: %{total_credits: 0.3, total_usage: 0.1}})
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
    Req.Test.stub(OpenRouter, &Req.Test.json(&1, %{data: %{limit: nil, usage_daily: nil}}))
    assert {:ok, %{balances: [], usage: [], limit: nil}} = OpenRouter.fetch("key")
  end

  test "scientific notation and oversized integer account credits subtract exactly" do
    trillion_trillions = "1" <> String.duplicate("0", 35)

    for {credits, usage, expected} <- [
          {"1e35", "0", trillion_trillions},
          {"1e35", "1", String.duplicate("9", 35)},
          {"100000000000000000000000000000000001", "1", trillion_trillions}
        ] do
      Req.Test.stub(OpenRouter, fn conn ->
        if conn.request_path == "/api/v1/key" do
          Req.Test.json(conn, %{data: %{usage: 1}})
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            ~s({"data":{"total_credits":#{credits},"total_usage":#{usage}}})
          )
        end
      end)

      assert {:ok, result} = OpenRouter.fetch("private-key", "management-secret")
      assert [%{total_balance: ^expected}] = result.balances
      assert result.warnings == []
      assert hd(result.usage) == %{label: "Key usage (all time)", amount: "1", currency: "USD"}
    end
  end

  test "optional account arithmetic overflow preserves key success with a safe warning" do
    Req.Test.stub(OpenRouter, fn conn ->
      if conn.request_path == "/api/v1/key" do
        Req.Test.json(conn, %{data: %{usage: 1}})
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"data":{"total_credits":9e6144,"total_usage":-9e6144}}))
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
      Req.Test.stub(OpenRouter, &Req.Test.json(&1, %{data: %{limit: 10, limit_reset: reset}}))
      assert {:ok, %{limit: %{reset: ^reset}}} = OpenRouter.fetch("private-key")
    end
  end

  test "unexpected or secret-bearing resets never enter a snapshot or error" do
    for reset <- ["private-key", "monthly private-key", "", "yearly"] do
      Req.Test.stub(OpenRouter, &Req.Test.json(&1, %{data: %{usage: 1, limit_reset: reset}}))
      assert {:error, :invalid_response} = result = OpenRouter.fetch("private-key")
      refute inspect(result) =~ "private-key"
    end
  end

  test "malformed key responses produce only safe errors" do
    for data <- [%{usage: "private-key"}, %{usage: false}, %{limit: []}, %{limit_reset: 42}] do
      Req.Test.stub(OpenRouter, &Req.Test.json(&1, %{data: data}))
      assert {:error, :invalid_response} = OpenRouter.fetch("private-key")
    end

    for body <- [%{}, %{data: []}, %{data: nil}] do
      Req.Test.stub(OpenRouter, &Req.Test.json(&1, body))
      assert {:error, :invalid_response} = OpenRouter.fetch("key")
    end
  end

  test "optional credit HTTP, network and parsing failures preserve successful key usage" do
    for failure <- [:http, :network, :malformed, :missing] do
      Req.Test.stub(OpenRouter, fn conn ->
        if conn.request_path == "/api/v1/key" do
          Req.Test.json(conn, %{data: %{usage: 1}})
        else
          case failure do
            :http ->
              Plug.Conn.send_resp(conn, 403, "management-secret")

            :network ->
              Req.Test.transport_error(conn, :timeout)

            :malformed ->
              Req.Test.json(conn, %{data: %{total_credits: "management-secret", total_usage: 0}})

            :missing ->
              Req.Test.json(conn, %{data: %{total_credits: 10}})
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
      Req.Test.expect(OpenRouter, fn conn ->
        assert conn.host == "openrouter.ai"

        conn
        |> Plug.Conn.put_resp_header("location", "https://example.com/private-key")
        |> Plug.Conn.send_resp(status, "private-key")
      end)

      assert {:error, {:http_error, ^status}} = OpenRouter.fetch("private-key")
    end
  end

  test "network and malformed JSON errors are redacted and not logged" do
    log =
      capture_log(fn ->
        Req.Test.stub(OpenRouter, &Req.Test.transport_error(&1, :timeout))
        assert {:error, :request_failed} = OpenRouter.fetch("private-key")

        Req.Test.stub(OpenRouter, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, "private-key")
        end)

        assert {:error, :invalid_response} = OpenRouter.fetch("private-key")
      end)

    refute log =~ "private-key"
  end

  test "request options enforce fixed endpoints, bounded timeouts and disabled logging" do
    Application.put_env(:backplane_monitor, :openrouter_req_options,
      adapter: InspectingAdapter,
      url: "https://example.com",
      auth: {:bearer, "wrong-key"},
      redirect: true,
      retry: true,
      receive_timeout: :infinity
    )

    assert {:ok, _result} = OpenRouter.fetch("key")
    assert_receive {:request, request}
    assert request.method == :get
    assert URI.to_string(request.url) == "https://openrouter.ai/api/v1/key"
    assert request.options.redirect == false
    assert request.options.retry == false
    assert request.options.redirect_log_level == false
    assert request.options.retry_log_level == false
    assert request.options.decode_body == false

    assert request.options.finch == [
             pool_timeout: 5_000,
             receive_timeout: 10_000,
             request_timeout: 15_000,
             conn_opts: [transport_opts: [timeout: 5_000]]
           ]

    assert Req.Request.get_header(request, "authorization") == ["Bearer key"]
  end

  test "adapter exceptions containing secrets are returned as safe request failures" do
    Application.put_env(:backplane_monitor, :openrouter_req_options, adapter: RaisingAdapter)

    log =
      capture_log(fn ->
        assert {:error, :request_failed} = OpenRouter.fetch("private-key")
      end)

    refute log =~ "private-key"
  end
end
