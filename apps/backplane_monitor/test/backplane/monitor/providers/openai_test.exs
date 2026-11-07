defmodule Backplane.Monitor.Providers.OpenAITest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Providers.OpenAI

  @now ~U[2026-11-07 12:00:00Z]
  @today DateTime.to_unix(~U[2026-11-07 00:00:00Z])
  @month DateTime.to_unix(~U[2026-11-01 00:00:00Z])

  setup do
    previous = Application.get_env(:backplane_monitor, :openai_req_options)
    Application.put_env(:backplane_monitor, :openai_req_options, plug: {Req.Test, OpenAI})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_monitor, :openai_req_options, previous),
        else: Application.delete_env(:backplane_monitor, :openai_req_options)
    end)

    :ok
  end

  test "fetches organization-wide paginated daily costs and completions with exact totals" do
    Req.Test.stub(OpenAI, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "api.openai.com"
      assert conn.scheme == :https
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer private-admin-key"]
      assert Plug.Conn.get_req_header(conn, "openai-organization") == ["org-selected"]
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.params["start_time"] == to_string(@month)
      assert conn.params["end_time"] == to_string(DateTime.to_unix(@now))
      assert conn.params["bucket_width"] == "1d"
      assert conn.params["limit"] == "31"
      refute Map.has_key?(conn.params, "api_key_ids")
      refute Map.has_key?(conn.params, "project_ids")

      case {conn.request_path, conn.params["page"]} do
        {"/v1/organization/costs", nil} ->
          Req.Test.json(conn, page([bucket(@month, [cost(0.1)])], "opaque cursor/1"))

        {"/v1/organization/costs", "opaque cursor/1"} ->
          Req.Test.json(conn, page([bucket(@today, [cost(0.2), cost(0.00001)])]))

        {"/v1/organization/usage/completions", nil} ->
          Req.Test.json(conn, page([bucket(@month, [usage(10, 2, 3, 1)])], "usage-next"))

        {"/v1/organization/usage/completions", "usage-next"} ->
          Req.Test.json(conn, page([bucket(@today, [usage(100, 20, 30, 4)])]))
      end
    end)

    assert {:ok, data} = OpenAI.fetch("private-admin-key", "org-selected", @now)
    assert data.balances == []
    assert data.limit == nil
    assert data.is_available == nil
    assert data.warnings == [{:account_balance, :not_supported}]

    assert data.usage == [
             %{label: "Organization spending (today, UTC)", amount: "0.20001", currency: "USD"},
             %{
               label: "Organization spending (month to date, UTC)",
               amount: "0.30001",
               currency: "USD"
             }
           ]

    assert Enum.map(data.metrics, &{&1.label, &1.amount, &1.unit}) == [
             {"Input tokens (today, UTC)", "100", "tokens"},
             {"Output tokens (today, UTC)", "20", "tokens"},
             {"Cached input tokens (today, UTC)", "30", "tokens"},
             {"Model requests (today, UTC)", "4", "requests"},
             {"Input tokens (month to date, UTC)", "110", "tokens"},
             {"Output tokens (month to date, UTC)", "22", "tokens"},
             {"Cached input tokens (month to date, UTC)", "33", "tokens"},
             {"Model requests (month to date, UTC)", "5", "requests"}
           ]

    refute inspect(data) =~ "private-admin-key"
    refute inspect(data) =~ "opaque cursor"
  end

  test "successful empty pages mean no activity, absent optional counters remain unavailable" do
    Req.Test.stub(OpenAI, &Req.Test.json(&1, page([])))
    assert {:ok, data} = OpenAI.fetch("key", "org-selected", @now)
    assert Enum.all?(data.usage ++ data.metrics, &(&1.amount == "0"))

    Req.Test.stub(OpenAI, fn conn ->
      result =
        if conn.request_path == "/v1/organization/costs",
          do: cost(1),
          else: Map.delete(usage(1, 2, 0, 3), :input_cached_tokens)

      Req.Test.json(conn, page([bucket(@today, [result])]))
    end)

    assert {:ok, data} = OpenAI.fetch("key", "org-selected", @now)
    refute Enum.any?(data.metrics, &String.starts_with?(&1.label, "Cached"))
  end

  test "partial failure preserves the successful endpoint and safe warnings" do
    for failed <- ["/v1/organization/costs", "/v1/organization/usage/completions"] do
      Req.Test.stub(OpenAI, fn conn ->
        if conn.request_path == failed do
          Plug.Conn.send_resp(conn, 403, "private-admin-key")
        else
          result =
            if conn.request_path == "/v1/organization/costs", do: cost(2), else: usage(1, 2, 0, 3)

          Req.Test.json(conn, page([bucket(@today, [result])]))
        end
      end)

      assert {:ok, data} = OpenAI.fetch("private-admin-key", "org-selected", @now)

      if failed == "/v1/organization/costs" do
        assert data.usage == []
        assert data.metrics != []
        assert {:organization_costs, {:http_error, 403}} in data.warnings
      else
        assert data.usage != []
        assert data.metrics == []
        assert {:organization_usage, {:http_error, 403}} in data.warnings
      end

      refute inspect(data) =~ "private-admin-key"
    end
  end

  test "authorization failures and redirects return only safe errors" do
    for status <- [301, 302, 307, 401, 403, 429, 500] do
      Req.Test.stub(OpenAI, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.invalid/private-admin-key")
        |> Plug.Conn.send_resp(status, "private-admin-key")
      end)

      assert {:error, {:http_error, ^status}} =
               OpenAI.fetch("private-admin-key", "org-selected", @now)
    end
  end

  test "malformed pages and cursor loops never return partial totals as a complete snapshot" do
    for body <- [
          %{},
          %{data: nil, has_more: false},
          page([bucket(@today, [%{amount: %{value: "private-admin-key", currency: "usd"}}])]),
          page([bucket(@today, [%{amount: %{value: 1, currency: "private-admin-key"}}])]),
          page([bucket(@today, [%{input_tokens: -1, output_tokens: 2, num_model_requests: 1}])]),
          page([%{start_time: "private-admin-key", results: []}]),
          page([], "repeated-cursor"),
          %{data: [], has_more: true, next_page: nil}
        ] do
      Req.Test.stub(OpenAI, &Req.Test.json(&1, body))
      assert {:error, :invalid_response} = result = OpenAI.fetch("key", "org-selected", @now)
      refute inspect(result) =~ "private-admin-key"
    end
  end

  test "validates explicit organization before sending requests" do
    for organization <- [
          nil,
          "",
          "org bad",
          "org-test\r\nx-extra: bad",
          String.duplicate("a", 256)
        ] do
      assert {:error, :invalid_organization} = OpenAI.fetch("key", organization, @now)
    end
  end

  test "UTC year/month rollover uses the current month only" do
    now = ~U[2027-01-01 00:01:00Z]
    start = DateTime.to_unix(~U[2027-01-01 00:00:00Z])

    Req.Test.stub(OpenAI, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.params["start_time"] == to_string(start)
      assert conn.params["end_time"] == to_string(DateTime.to_unix(now))
      Req.Test.json(conn, page([]))
    end)

    assert {:ok, data} = OpenAI.fetch("key", "org-selected", now)
    assert Enum.all?(data.usage ++ data.metrics, &(&1.amount == "0"))
  end

  defp cost(value), do: %{amount: %{value: value, currency: "usd"}}

  defp usage(input, output, cached, requests),
    do: %{
      input_tokens: input,
      output_tokens: output,
      input_cached_tokens: cached,
      num_model_requests: requests
    }

  defp bucket(start, results),
    do: %{object: "bucket", start_time: start, end_time: start + 86_400, results: results}

  defp page(data, cursor \\ nil), do: %{data: data, has_more: cursor != nil, next_page: cursor}
end
