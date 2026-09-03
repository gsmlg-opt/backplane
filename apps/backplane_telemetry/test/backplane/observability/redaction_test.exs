defmodule Backplane.Observability.RedactionTest do
  use ExUnit.Case, async: true

  alias Backplane.Observability.Redaction

  test "redacts credential keys and embedded bearer tokens" do
    assert Redaction.redact(%{"authorization" => "Bearer secret-token"}) == %{
             "authorization" => "[REDACTED]"
           }

    assert Redaction.redact("failed with Bearer embedded-secret") ==
             "failed with Bearer [REDACTED]"
  end

  test "redacts payload-classified keys" do
    assert Redaction.redact(%{"messages" => [%{"content" => "hello"}]}) == %{
             "messages" => "[REDACTED]"
           }
  end

  test "sanitizes attributes for JSON output" do
    sanitized =
      Redaction.sanitize_attributes(%{
        provider: "anthropic",
        token: "secret",
        pid: self()
      })

    assert sanitized["provider"] == "anthropic"
    assert sanitized["token"] == "[REDACTED]"
    assert sanitized["pid"] == inspect(self())
  end
end
