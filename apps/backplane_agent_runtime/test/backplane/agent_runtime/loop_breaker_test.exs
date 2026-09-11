defmodule Backplane.AgentRuntime.LoopBreakerTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.LoopBreaker

  describe "hard loop breakers" do
    test "records semantically identical work and ignores superficial changes" do
      {:ok, breaker} = LoopBreaker.new(2)

      assert {:ok, breaker, %{status: :recorded, count: 1}} =
               LoopBreaker.record(breaker, "attempt_1", %{tool: "example", arguments: %{}}, %{
                 nonce: "one"
               })

      assert {:ok, _breaker, %{status: :duplicate, count: 2}} =
               LoopBreaker.record(breaker, "attempt_2", %{tool: "example", arguments: %{}}, %{
                 nonce: "different"
               })
    end

    test "terminates known work at the hard limit" do
      {:ok, breaker} = LoopBreaker.new(1)

      assert {:ok, breaker, %{status: :recorded, count: 1}} =
               LoopBreaker.record(breaker, "attempt_1", %{tool: "example", arguments: %{}})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               LoopBreaker.record(breaker, "attempt_2", %{tool: "example", arguments: %{}}, %{
                 nonce: "different"
               })
    end

    test "distinguishes semantically different operations" do
      {:ok, breaker} = LoopBreaker.new(1)

      assert {:ok, breaker, %{status: :recorded, count: 1}} =
               LoopBreaker.record(breaker, "attempt_1", %{tool: "example", arguments: %{}}, %{
                 nonce: "one"
               })

      assert {:ok, _breaker, %{status: :recorded, count: 1}} =
               LoopBreaker.record(breaker, "attempt_2", %{tool: "other", arguments: %{}}, %{
                 nonce: "different"
               })
    end
  end
end
