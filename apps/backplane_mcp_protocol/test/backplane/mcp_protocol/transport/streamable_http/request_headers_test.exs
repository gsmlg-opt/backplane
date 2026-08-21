defmodule Backplane.McpProtocol.Transport.StreamableHTTP.RequestHeadersTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Transport.StreamableHTTP.RequestHeaders

  test "returns static headers when no provider is configured" do
    assert {:ok, %{"authorization" => "Bearer static"}} =
             RequestHeaders.resolve(%{"authorization" => "Bearer static"}, nil)
  end

  test "merges dynamic headers over static headers on every call" do
    counter = start_supervised!({Agent, fn -> 0 end})

    provider = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      {:ok, %{"authorization" => "Bearer token-#{value}"}}
    end

    assert {:ok, %{"authorization" => "Bearer token-1", "x-static" => "one"}} =
             RequestHeaders.resolve(
               %{"authorization" => "Bearer old", "x-static" => "one"},
               provider
             )

    assert {:ok, %{"authorization" => "Bearer token-2", "x-static" => "one"}} =
             RequestHeaders.resolve(
               %{"authorization" => "Bearer old", "x-static" => "one"},
               provider
             )
  end

  test "normalizes header names before dynamic headers override static headers" do
    provider = fn -> {:ok, %{"authorization" => "Bearer dynamic"}} end

    assert {:ok,
            %{
              "authorization" => "Bearer dynamic",
              "x-static" => "one"
            }} =
             RequestHeaders.resolve(
               %{"Authorization" => "Bearer static", "X-Static" => "one"},
               provider
             )
  end

  test "rejects duplicate static header names before resolving either provider path" do
    static = %{
      "Authorization" => "Bearer first",
      "authorization" => "Bearer second"
    }

    assert {:error, {:duplicate_header, "authorization"}} =
             RequestHeaders.resolve(static, nil)

    test_pid = self()

    assert {:error, {:duplicate_header, "authorization"}} =
             RequestHeaders.resolve(static, fn ->
               send(test_pid, :provider_called)
               {:ok, %{"authorization" => "Bearer dynamic"}}
             end)

    refute_receive :provider_called
  end

  test "returns configured header errors for malformed static maps on both provider paths" do
    cases = [
      {%{123 => "value"}, {:invalid_header_name, 123}},
      {%{"X-Unsafe" => "line one\r\nline two"}, {:invalid_header_value, "x-unsafe"}}
    ]

    for {static, expected_error} <- cases do
      assert {:error, ^expected_error} = RequestHeaders.resolve(static, nil)

      assert {:error, ^expected_error} =
               RequestHeaders.resolve(static, fn -> {:ok, %{"x-dynamic" => "value"}} end)
    end
  end

  test "returns configured header errors for malformed dynamic maps" do
    cases = [
      {%{"X-Dynamic" => "one", "x-dynamic" => "two"}, {:duplicate_header, "x-dynamic"}},
      {%{123 => "value"}, {:invalid_header_name, 123}},
      {%{"X-Unsafe" => "line one\nline two"}, {:invalid_header_value, "x-unsafe"}}
    ]

    for {dynamic, expected_error} <- cases do
      assert {:error, ^expected_error} =
               RequestHeaders.resolve(%{"x-static" => "value"}, fn -> {:ok, dynamic} end)
    end
  end

  test "returns a sanitized error for invalid provider values and arities" do
    for provider <- [:not_a_function, fn _value -> {:ok, %{}} end] do
      assert {:error, :invalid_headers_provider_result} =
               RequestHeaders.resolve(%{}, provider)
    end
  end

  test "returns sanitized invalid results and explicit provider failures" do
    assert {:error, :invalid_headers_provider_result} =
             RequestHeaders.resolve(%{}, fn -> {:ok, ["bad"]} end)

    assert {:error, :invalid_headers_provider_result} =
             RequestHeaders.resolve(%{}, fn -> :unexpected end)

    assert {:error, :credential_unavailable} =
             RequestHeaders.resolve(%{}, fn -> {:error, :credential_unavailable} end)
  end

  test "sanitizes provider exceptions and non-local exits" do
    assert {:error, :headers_provider_failed} =
             RequestHeaders.resolve(%{}, fn -> raise "secret failure" end)

    assert {:error, :headers_provider_failed} =
             RequestHeaders.resolve(%{}, fn -> throw(:secret_failure) end)

    assert {:error, :headers_provider_failed} =
             RequestHeaders.resolve(%{}, fn -> exit(:secret_failure) end)
  end
end
