defmodule Backplane.HostAgent.Memory.EventEnvelopeTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.{EventEnvelope, PrivacyFilter}

  test "builds a canonical v1 envelope after filtering private data" do
    payload = %{
      "note" => "keep <private>never store this</private> safe",
      "nested" => %{"token" => "sk-secret", "value" => 1},
      password: "hunter2"
    }

    {filtered, privacy} = PrivacyFilter.filter(payload)

    assert {:ok, envelope} = EventEnvelope.build(valid_attrs(filtered, privacy))
    assert envelope["schema_version"] == 1
    assert envelope["payload_hash"] == EventEnvelope.payload_hash(filtered)
    refute EventEnvelope.encode!(envelope) =~ "hunter2"
    refute EventEnvelope.encode!(envelope) =~ "never store this"
    refute EventEnvelope.encode!(envelope) =~ "sk-secret"

    assert privacy == %{
             "filtered" => true,
             "filter_version" => "1",
             "redaction_count" => 2,
             "private_blocks_removed" => 1
           }
  end

  test "counts private blocks nested inside a discarded secret value" do
    payload = %{
      "api_key" => %{
        "primary" => "<private>first secret</private>",
        "fallbacks" => ["public", "<private>second secret</private>"]
      }
    }

    assert {filtered, privacy} = PrivacyFilter.filter(payload)
    assert filtered == %{"api_key" => "[REDACTED]"}
    assert privacy["redaction_count"] == 1
    assert privacy["private_blocks_removed"] == 2
    refute Jason.encode!(filtered) =~ "first secret"
    refute Jason.encode!(filtered) =~ "second secret"
  end

  test "redacts explicit secret keys without redacting benign token metrics" do
    payload = %{
      "access_token" => "access-secret",
      "api_key" => "api-secret",
      "client_secret" => "client-secret",
      "password" => "password-secret",
      "private_key" => "private-secret",
      "token" => "token-secret",
      "token_count" => 12,
      "token_usage" => %{"input" => 8},
      "token_budget" => 100,
      "token_estimate" => 20,
      "authorization_status" => "approved"
    }

    {filtered, privacy} = PrivacyFilter.filter(payload)

    for key <- ~w(access_token api_key client_secret password private_key token) do
      assert filtered[key] == "[REDACTED]"
    end

    assert Map.take(
             filtered,
             ~w(token_count token_usage token_budget token_estimate authorization_status)
           ) ==
             Map.take(
               payload,
               ~w(token_count token_usage token_budget token_estimate authorization_status)
             )

    assert privacy["redaction_count"] == 6
  end

  test "redacts provider-prefixed secret keys and recognized token formats" do
    github_token = "ghp_" <> String.duplicate("a", 36)

    payload = %{
      "env" => %{
        "OPENAI_API_KEY" => "arbitrary-secret-value",
        "github_token" => "another-secret-value",
        "token_count" => 42
      },
      "log" => "request used #{github_token}",
      "config" => "api_key=abcdefghijklmnopqrstuvwxyz123456"
    }

    {filtered, privacy} = PrivacyFilter.filter(payload)
    encoded = Jason.encode!(filtered)

    assert filtered["env"]["OPENAI_API_KEY"] == "[REDACTED]"
    assert filtered["env"]["github_token"] == "[REDACTED]"
    assert filtered["env"]["token_count"] == 42
    refute encoded =~ "arbitrary-secret-value"
    refute encoded =~ "another-secret-value"
    refute encoded =~ github_token
    refute encoded =~ "abcdefghijklmnopqrstuvwxyz123456"
    assert privacy["redaction_count"] == 4
  end

  test "normalizes atom and string keys and preserves optional fields" do
    attrs =
      valid_attrs(%{"ok" => true}, privacy())
      |> Map.merge(%{
        client_id: "codex",
        project: "/workspace/backplane",
        scope: "project:backplane",
        parent_session_id: "parent-1",
        trace: %{correlation_id: "correlation-1"}
      })

    assert {:ok, envelope} = EventEnvelope.build(attrs)

    assert Map.take(envelope, ~w(client_id project scope parent_session_id captured_at trace)) ==
             %{
               "client_id" => "codex",
               "project" => "/workspace/backplane",
               "scope" => "project:backplane",
               "parent_session_id" => "parent-1",
               "captured_at" => "2026-08-03T10:00:00.010Z",
               "trace" => %{"correlation_id" => "correlation-1"}
             }

    refute Map.has_key?(envelope, :client_id)
  end

  test "rejects missing fields, unsupported schema, bad timestamps, sequence, and hash" do
    attrs = valid_attrs(%{}, privacy())
    assert {:error, errors} = EventEnvelope.validate(Map.delete(attrs, :event_id))
    assert :event_id in errors
    assert {:error, errors} = EventEnvelope.validate(%{attrs | schema_version: 2})
    assert :schema_version in errors
    assert {:error, errors} = EventEnvelope.validate(%{attrs | occurred_at: "yesterday"})
    assert :occurred_at in errors
    assert {:error, errors} = EventEnvelope.validate(%{attrs | captured_at: "later"})
    assert :captured_at in errors
    assert {:error, errors} = EventEnvelope.validate(%{attrs | sequence: 0})
    assert :sequence in errors
    assert {:error, errors} = EventEnvelope.validate(%{attrs | payload_hash: "sha256:nope"})
    assert :payload_hash in errors
  end

  test "rejects blank and non-string required identifiers" do
    attrs = valid_attrs(%{}, privacy())

    for {field, value} <- [event_id: " ", host_id: 123, agent_id: nil, integration: ""] do
      assert {:error, errors} = EventEnvelope.validate(Map.put(attrs, field, value))
      assert field in errors
    end
  end

  test "requires privacy, payload, and optional trace to be maps" do
    attrs = valid_attrs(%{}, privacy())

    for {field, value} <- [privacy: [], payload: "payload", trace: []] do
      assert {:error, errors} = EventEnvelope.validate(Map.put(attrs, field, value))
      assert field in errors
    end
  end

  test "requires sequence only for session-bound events" do
    attrs = valid_attrs(%{}, privacy())

    assert {:error, errors} = EventEnvelope.validate(Map.delete(attrs, :sequence))
    assert :sequence in errors

    non_session =
      attrs
      |> Map.put(:event_type, "git.commit.created")
      |> Map.delete(:session_id)
      |> Map.delete(:sequence)

    assert {:ok, envelope} = EventEnvelope.validate(non_session)
    refute Map.has_key?(envelope, "session_id")
    refute Map.has_key?(envelope, "sequence")
  end

  test "returns validation errors for arbitrary malformed event types" do
    attrs = valid_attrs(%{}, privacy())

    for malformed <- [123, %{"bad" => true}, nil] do
      assert {:error, errors} = EventEnvelope.validate(Map.put(attrs, :event_type, malformed))
      assert :event_type in errors
    end
  end

  test "returns payload errors for non-JSON nested keys and values" do
    invalid_payloads = [
      %{{:tuple, :key} => "value"},
      %{"nested" => %{"pid" => self()}},
      %{"reference" => make_ref()},
      %{"function" => fn -> :ok end},
      %{"tuple" => {:not, :json}},
      [1 | 2],
      %{"nested" => [1 | 2]}
    ]

    for payload <- invalid_payloads do
      attrs = valid_attrs(%{}, privacy()) |> Map.put(:payload, payload)
      assert {:error, errors} = EventEnvelope.validate(attrs)
      assert :payload in errors
      assert {:error, build_errors} = EventEnvelope.build(attrs)
      assert :payload in build_errors
    end
  end

  defp valid_attrs(payload, privacy) do
    %{
      event_id: "event-1",
      schema_version: 1,
      host_id: "host-1",
      agent_id: "agent-1",
      integration: "codex",
      session_id: "session-1",
      sequence: 1,
      event_type: "agent.prompt.submitted",
      occurred_at: "2026-08-03T10:00:00.000Z",
      captured_at: "2026-08-03T10:00:00.010Z",
      idempotency_key: "codex:session-1:1",
      payload_hash: EventEnvelope.payload_hash(payload),
      privacy: privacy,
      trace: %{},
      payload: payload
    }
  end

  defp privacy,
    do: %{
      "filtered" => true,
      "filter_version" => "1",
      "redaction_count" => 0,
      "private_blocks_removed" => 0
    }
end
