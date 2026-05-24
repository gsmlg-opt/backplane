defmodule BackplaneMemory.Embedding.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias BackplaneMemory.Embedding.CircuitBreaker

  setup do
    CircuitBreaker.reset()
    :ok
  end

  test "starts closed" do
    assert CircuitBreaker.state() == :closed
    assert CircuitBreaker.allow_request?() == true
  end

  test "opens after 5 consecutive failures" do
    for _ <- 1..5, do: CircuitBreaker.record_failure()
    assert CircuitBreaker.state() == :open
    assert CircuitBreaker.allow_request?() == false
  end

  test "reset returns to closed" do
    for _ <- 1..5, do: CircuitBreaker.record_failure()
    CircuitBreaker.reset()
    assert CircuitBreaker.state() == :closed
    assert CircuitBreaker.allow_request?() == true
  end

  test "4 failures stays closed" do
    for _ <- 1..4, do: CircuitBreaker.record_failure()
    assert CircuitBreaker.state() == :closed
  end
end
