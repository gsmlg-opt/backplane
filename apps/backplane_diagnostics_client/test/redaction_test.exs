defmodule Backplane.DiagnosticsClient.RedactionTest do
  use ExUnit.Case, async: true

  alias Backplane.DiagnosticsClient.{Envelope, Redaction}

  test "allowlists every evidence level and removes credentials before hashing" do
    event =
      "../../../docs/diagnostics/protocol/v1/event.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Formata.JSON.decode!()

    sentinel = "diagnostics-secret-fixture"

    event =
      event
      |> Map.put("SeT-CooKie", sentinel)
      |> put_in(["version", "ENVIRONMENT"], %{"PATH" => sentinel})
      |> put_in(["evidence", "RAW_response"], sentinel)
      |> put_in(["evidence", "exception", "message"], "Authorization: Bearer #{sentinel}")
      |> put_in(["evidence", "exception", "stack"], [
        %{
          "module" => "Example",
          "line" => 42,
          "file" => "postgres://operator:#{sentinel}@localhost/db",
          "arguments" => [sentinel]
        }
      ])
      |> put_in(["evidence", "breadcrumbs"], [
        %{
          "kind" => "provider_response",
          "summary" => "X.ApI KEY = #{sentinel}",
          "prompt" => sentinel
        }
      ])

    projected = Redaction.project(event)
    assert {:ok, bytes, _} = Envelope.seal(projected)
    refute bytes =~ sentinel
    refute bytes =~ "SeT-CooKie"
    refute bytes =~ "ENVIRONMENT"
    refute bytes =~ "RAW_response"
    refute bytes =~ "arguments"
    refute bytes =~ "prompt"

    assert get_in(projected, ["evidence", "exception", "stack"]) == [
             %{"module" => "Example", "line" => 42}
           ]

    assert get_in(projected, ["evidence", "exception", "message"]) == "[REDACTED]"

    assert get_in(projected, ["quality", "redaction_policy_version"]) ==
             Redaction.policy_version()

    assert projected == Redaction.project(projected)
  end

  test "suppresses ambiguous content and bounds evidence text in bytes" do
    for value <- [
          "Cookie: test=synthetic",
          "client-secret='synthetic'",
          "Tool.Result: private body",
          "api key: fixture",
          "password=something",
          "Basic c3ludGhldGlj",
          <<255>>
        ] do
      assert "[REDACTED]" == Redaction.summary(value, 256)
    end

    assert "[TRUNCATED]" == Redaction.summary(String.duplicate("界", 400), 1024)
    assert "provider timeout" == Redaction.summary("provider timeout", 1024)
  end
end
