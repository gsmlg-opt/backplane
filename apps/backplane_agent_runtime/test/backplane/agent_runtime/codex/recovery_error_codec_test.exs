defmodule Backplane.AgentRuntime.Codex.RecoveryErrorCodecTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  test "ordinary committed Runtime errors preserve every field in canonical JSON" do
    error =
      Error.new(:not_found, "command session is unknown\r\n你好",
        details: %{operation: "write_stdin"},
        cause: Error.new(:execution_failure, "retained", cause: %{code: 3})
      )

    expected = %{
      "class" => "not_found",
      "message" => error.message,
      "details" => %{"operation" => "write_stdin"},
      "cause" => %{
        "class" => "execution_failure",
        "message" => "retained",
        "details" => %{},
        "cause" => %{"code" => 3}
      }
    }

    assert {:ok, ^expected} = Evidence.public(error)
    assert Evidence.digest(error) == Evidence.digest(expected)
    assert JSON.decode!(JSON.encode!(expected)) == expected

    assert {:ok, %{"result" => %{"error" => ^expected, "is_error" => true}}} =
             Evidence.public(%{result: %{is_error: true, error: error}})
  end

  test "unrepresentable Error causes are never dropped or inspected" do
    for cause <- [
          self(),
          make_ref(),
          fn -> :ok end,
          %{"a" => 2, :a => 1},
          ~U[2026-10-27 00:00:00Z]
        ] do
      assert {:error, %Error{class: :validation}} =
               Evidence.public(Error.new(:execution_failure, "retained", cause: cause))
    end
  end
end
