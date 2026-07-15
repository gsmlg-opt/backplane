defmodule Backplane.Memory.Privacy.FilterTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Privacy.Filter

  describe "apply/1" do
    test "redacts atom sensitive keys" do
      {:ok, e} =
        Filter.apply_event(%{
          stream_id: "s",
          event_type: "heartbeat.triggered",
          payload: %{password: "secret"}
        })

      assert e.payload.password == "[REDACTED]"
    end

    test "sanitizes sensitive keys recursively" do
      {:ok, e} =
        Filter.apply_event(%{
          "stream_id" => "s",
          "event_type" => "heartbeat.triggered",
          "idempotency_key" => "heartbeat-1",
          "content" => "ok",
          "payload" => %{"Authorization" => "secret", "nested" => %{"password" => "x"}}
        })

      assert e.payload["Authorization"] == "[REDACTED]"
      assert e.payload["nested"]["password"] == "[REDACTED]"
      assert is_binary(e.payload["_backplane"]["event_fingerprint"])
    end

    test "sanitizes nested headers, environment values, tool text, private tags, and null bytes" do
      sentinel = "hunter2-raw-sentinel"

      {:ok, event} =
        Filter.apply_event(%{
          stream_id: "s",
          event_type: "tool.call.failed",
          content: "visible\0 <private>#{sentinel}</private> password=#{sentinel}",
          payload: %{
            "headers" => %{
              "Authorization" => "Bearer #{sentinel}",
              "Cookie" => "session=#{sentinel}",
              "Set-Cookie" => "session=#{sentinel}"
            },
            "environment" => %{
              "DATABASE_PASSWORD" => sentinel,
              "OPENAI_API_KEY" => sentinel,
              "AWS_ACCESS_KEY_ID" => sentinel
            },
            "tool" => %{
              "input" => "password=#{sentinel}\0",
              "output" => ["token=#{sentinel}", "<private>#{sentinel}</private>"],
              "error" => "secret: #{sentinel}"
            },
            "pass\0word" => sentinel
          }
        })

      encoded = Jason.encode!(event)

      refute encoded =~ sentinel
      refute encoded =~ "<private>"
      refute encoded =~ "\\u0000"
      assert encoded =~ "[REDACTED]"
      assert event.content =~ "visible"
    end

    test "uses the legacy empty-string behavior for nonbinary event content" do
      assert {:ok, event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "heartbeat.triggered",
                 content: %{unexpected: "value"}
               })

      assert event.content == ""
    end

    test "content truncation is grapheme and byte bounded" do
      {:ok, e} =
        Filter.apply_event(%{
          "stream_id" => "s",
          "event_type" => "heartbeat.triggered",
          "content" => String.duplicate("é", 40_000)
        })

      assert byte_size(e.content) <= 65_536
      assert e.payload["_backplane"]["content"]["truncated"]
    end

    test "content limits use exact UTF-8 byte boundaries without splitting graphemes" do
      exact = String.duplicate("a", 65_536)

      assert {:ok, exact_event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "heartbeat.triggered",
                 content: exact
               })

      assert exact_event.content == exact
      refute exact_event.payload["_backplane"]["content"]["truncated"]

      over = String.duplicate("a", 65_535) <> "💾"

      assert {:ok, over_event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "heartbeat.triggered",
                 content: over
               })

      assert over_event.content == String.duplicate("a", 65_535)
      assert byte_size(over_event.content) <= 65_536
      assert String.valid?(over_event.content)
      assert over_event.payload["_backplane"]["content"]["truncated"]
      assert over_event.payload["_backplane"]["content"]["original_bytes"] == byte_size(over)
    end

    test "previews contain at most 512 Unicode graphemes" do
      assert {:ok, event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "heartbeat.triggered",
                 content: String.duplicate("😀", 600)
               })

      preview = event.payload["_backplane"]["content"]["preview"]
      assert String.length(preview) == 512
      assert preview == String.duplicate("😀", 512)
    end

    test "content digests and previews derive from the full sanitized value" do
      raw_secret = "digest-secret-sentinel"
      raw_content = "prefix password=#{raw_secret} suffix"
      {:ok, sanitized_content} = Filter.apply(raw_content)

      assert {:ok, event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "heartbeat.triggered",
                 content: raw_content
               })

      metadata = event.payload["_backplane"]["content"]
      assert metadata["sha256"] == sha256(sanitized_content)
      refute metadata["sha256"] == sha256(raw_content)
      refute metadata["preview"] =~ raw_secret
    end

    test "persists a sanitized fingerprint only for idempotent events" do
      raw_secret = "fingerprint-secret-sentinel"

      base = %{
        stream_id: "s",
        event_type: "tool.call.completed",
        content: "password=#{raw_secret}",
        payload: %{"result" => "ok"}
      }

      assert {:ok, non_idempotent} = Filter.apply_event(base)
      refute Map.has_key?(non_idempotent, :fingerprint)
      refute Map.has_key?(non_idempotent.payload["_backplane"], "event_fingerprint")

      assert {:ok, first} =
               Filter.apply_event(
                 base
                 |> Map.put(:idempotency_key, "tool-use-1")
                 |> put_in([:payload, "_backplane"], %{"legacy_observation_id" => "one"})
               )

      assert {:ok, retry} =
               Filter.apply_event(
                 base
                 |> Map.put(:idempotency_key, "tool-use-1")
                 |> put_in([:payload, "_backplane"], %{"legacy_observation_id" => "two"})
               )

      assert {:ok, changed} =
               Filter.apply_event(
                 Map.merge(base, %{
                   idempotency_key: "tool-use-1",
                   payload: %{"result" => "changed"}
                 })
               )

      first_fingerprint = first.payload["_backplane"]["event_fingerprint"]
      assert first_fingerprint == retry.payload["_backplane"]["event_fingerprint"]
      refute first_fingerprint == changed.payload["_backplane"]["event_fingerprint"]

      raw_fingerprint =
        sha256(
          Jason.encode!(%{
            stream_id: base.stream_id,
            event_type: base.event_type,
            content: base.content,
            payload: base.payload
          })
        )

      refute first_fingerprint == raw_fingerprint
      refute Jason.encode!(first) =~ raw_secret
    end

    test "replaces a near-boundary payload when required metadata crosses the final limit" do
      business_payload = %{"blob" => String.duplicate("x", 262_000)}
      assert byte_size(Jason.encode!(business_payload)) <= 262_144

      assert {:ok, event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "heartbeat.triggered",
                 payload: business_payload
               })

      assert byte_size(Jason.encode!(event.payload)) <= 262_144
      assert Map.keys(event.payload) == ["_backplane"]
      assert event.payload["_backplane"]["payload"]["truncated"]
      assert is_map(event.payload["_backplane"]["content"])
    end

    test "bounds oversized payload metadata and hashes only the sanitized full payload" do
      raw_secret = "payload-digest-raw-sentinel"

      raw_payload = %{
        "_backplane" => %{"legacy_observation_id" => "legacy-1"},
        "blob" => String.duplicate("😀", 70_000),
        "password" => raw_secret
      }

      sanitized_payload = %{raw_payload | "password" => "[REDACTED]"}

      assert {:ok, event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "tool.call.failed",
                 idempotency_key: "tool-use-oversized",
                 content: "safe",
                 payload: raw_payload
               })

      encoded = Jason.encode!(event.payload)
      metadata = event.payload["_backplane"]
      payload_metadata = metadata["payload"]

      assert byte_size(encoded) <= 262_144
      assert Map.keys(event.payload) == ["_backplane"]
      assert payload_metadata["truncated"]
      assert payload_metadata["original_bytes"] == byte_size(Jason.encode!(sanitized_payload))
      assert payload_metadata["sha256"] == sha256(Jason.encode!(sanitized_payload))
      refute payload_metadata["sha256"] == sha256(Jason.encode!(raw_payload))
      assert String.length(payload_metadata["preview"]) == 512
      assert is_map(metadata["content"])
      assert is_binary(metadata["event_fingerprint"])
      refute encoded =~ raw_secret
      refute inspect(event.payload) =~ raw_secret
    end

    test "preserves only bounded legacy linkage when replacing an oversized payload" do
      legacy_observation_id = Ecto.UUID.generate()

      assert {:ok, event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "tool.call.completed",
                 idempotency_key: "tool-use-linked-oversized",
                 content: "linked observation",
                 payload: %{
                   "_backplane" => %{
                     "legacy_observation_id" => legacy_observation_id,
                     "caller_controlled" => String.duplicate("secret", 1_000)
                   },
                   "blob" => String.duplicate("x", 262_144)
                 }
               })

      encoded = Jason.encode!(event.payload)
      metadata = event.payload["_backplane"]

      assert byte_size(encoded) <= 262_144
      assert Map.keys(event.payload) == ["_backplane"]
      assert metadata["legacy_observation_id"] == legacy_observation_id
      refute Map.has_key?(metadata, "caller_controlled")
      assert is_map(metadata["content"])
      assert metadata["payload"]["truncated"]
      assert is_binary(metadata["event_fingerprint"])
    end

    test "keeps the final payload bounded when a single preview grapheme is enormous" do
      one_large_grapheme = "a" <> String.duplicate("\u0301", 140_000)
      assert String.length(one_large_grapheme) == 1

      assert {:ok, event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "heartbeat.triggered",
                 payload: %{"blob" => one_large_grapheme}
               })

      assert byte_size(Jason.encode!(event.payload)) <= 262_144
      assert String.length(event.payload["_backplane"]["payload"]["preview"]) <= 512
    end

    test "fingerprints use full sanitized values before truncation" do
      prefix = String.duplicate("a", 65_537)

      attrs = %{
        stream_id: "s",
        event_type: "heartbeat.triggered",
        idempotency_key: "same-key",
        content: prefix <> "first"
      }

      assert {:ok, first} = Filter.apply_event(attrs)
      assert {:ok, second} = Filter.apply_event(%{attrs | content: prefix <> "second"})
      assert first.content == second.content

      refute first.payload["_backplane"]["event_fingerprint"] ==
               second.payload["_backplane"]["event_fingerprint"]
    end

    test "fingerprints use recursively key-sorted canonical JSON" do
      assert {:ok, event} =
               Filter.apply_event(%{
                 stream_id: "s",
                 event_type: "task.created",
                 idempotency_key: "task-1",
                 content: "ok",
                 payload: %{"z" => 2, "nested" => %{"b" => 2, "a" => 1}, "a" => 1}
               })

      canonical =
        ~s({"content":"ok","event_type":"task.created","payload":{"a":1,"nested":{"a":1,"b":2},"z":2},"stream_id":"s"})

      assert event.payload["_backplane"]["event_fingerprint"] == sha256(canonical)
    end

    test "passes through normal content unchanged" do
      assert Filter.apply("The meeting is at 3pm.") == {:ok, "The meeting is at 3pm."}
    end

    test "strips PostgreSQL null bytes while preserving the legacy tuple contract" do
      assert Filter.apply("before\0after") == {:ok, "beforeafter"}
      assert Filter.apply(%{not: "a string"}) == {:ok, ""}
    end

    test "strips <private> tagged content" do
      assert Filter.apply("<private>my secret</private>") == {:ok, "[REDACTED]"}
    end

    test "strips OpenAI/Anthropic-style API keys (sk- prefix)" do
      input = "Use key sk-1234567890abcdefABCDEFabcdef123456"
      {:ok, result} = Filter.apply(input)
      refute result =~ "sk-1234567890"
      assert result =~ "[REDACTED]"
    end

    test "strips AWS access key IDs (AKIA prefix)" do
      input = "AKIA1234567890ABCDEF is the key"
      {:ok, result} = Filter.apply(input)
      refute result =~ "AKIA1234567890ABCDEF"
      assert result =~ "[REDACTED]"
    end

    test "strips api_key assignment patterns" do
      input = ~s(api_key = "abcdefghijklmnopqrstuvwxyz12345")
      {:ok, result} = Filter.apply(input)
      refute result =~ "abcdefghijklmnopqrstuvwxyz12345"
      assert result =~ "[REDACTED]"
    end

    test "strips GitHub personal access tokens (ghp_ prefix)" do
      input = "token: ghp_abcdefghijklmnopqrstuvwxyz1234567890AB"
      {:ok, result} = Filter.apply(input)
      refute result =~ "ghp_"
      assert result =~ "[REDACTED]"
    end

    test "strips Authorization: Bearer header tokens" do
      input = "Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.payload"
      {:ok, result} = Filter.apply(input)
      refute result =~ "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
      assert result =~ "[REDACTED]"
    end

    test "multi-line content: strips only the private block" do
      input = "Facts:\n<private>my password</private>\nMore facts."
      {:ok, result} = Filter.apply(input)
      assert result =~ "Facts:"
      assert result =~ "More facts."
      refute result =~ "my password"
    end
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
