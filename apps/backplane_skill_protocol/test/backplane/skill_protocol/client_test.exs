defmodule Backplane.SkillProtocol.ClientTest do
  use ExUnit.Case, async: true

  alias Backplane.SkillProtocol.{Client, Descriptor, Error, SkillRef}

  @digest "sha256:" <> String.duplicate("a", 64)

  test "catalog decodes one page, preserves opaque IDs, and sends opaque cursors" do
    parent = self()

    transport = fn request ->
      send(parent, {:request, request})

      {:ok,
       %{
         status: 200,
         headers: %{"content-type" => "application/json"},
         body:
           JSON.encode!(%{
             "protocol_version" => "1",
             "data" => [
               %{
                 "skill_id" => "team/skill with spaces",
                 "name" => "example-skill",
                 "description" => "Example",
                 "revision" => "rev/one",
                 "artifact_digest" => @digest,
                 "publication_status" => "ready"
               }
             ],
             "next_cursor" => "next/page+token"
           })
       }}
    end

    client = client(transport)

    assert {:ok,
            %{
              data: [
                %Descriptor{
                  ref: %SkillRef{source_id: "source-a", skill_id: "team/skill with spaces"}
                }
              ],
              next_cursor: "next/page+token"
            }} =
             Client.catalog(client,
               cursor: "cursor/with+symbols",
               limit: 1,
               q: "text/value",
               tag: "ops"
             )

    assert_receive {:request, %{url: url, headers: %{"authorization" => "Bearer secret"}}}

    assert URI.decode_query(URI.parse(url).query) == %{
             "cursor" => "cursor/with+symbols",
             "limit" => "1",
             "q" => "text/value",
             "tag" => "ops"
           }
  end

  test "resolve encodes opaque identity as query values and rejects mismatched manifests" do
    parent = self()

    transport = fn request ->
      send(parent, {:request, request})
      {:ok, %{status: 200, headers: %{}, body: JSON.encode!(manifest("other", "rev/1"))}}
    end

    assert {:error, %Error{code: :integrity_mismatch}} =
             Client.resolve(client(transport), "opaque/id", "rev/1")

    assert_receive {:request, %{url: url}}

    assert URI.decode_query(URI.parse(url).query) == %{
             "revision" => "rev/1",
             "skill_id" => "opaque/id"
           }
  end

  test "malformed and oversized JSON are terminal" do
    for body <- ["{", String.duplicate("x", 33)] do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      transport = fn _request ->
        Agent.update(calls, &(&1 + 1))
        {:ok, %{status: 200, headers: %{}, body: body}}
      end

      assert {:error, %Error{retryable: false}} =
               Client.catalog(client(transport, max_json_bytes: 32))

      assert Agent.get(calls, & &1) == 1
    end
  end

  test "429 and transient failures retry at most three total attempts" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    transport = fn _request ->
      Agent.update(calls, &(&1 + 1))

      {:ok,
       %{
         status: 429,
         headers: %{"retry-after" => "0"},
         body: error_body("temporarily_unavailable", true)
       }}
    end

    assert {:error, %Error{code: :temporarily_unavailable, retryable: true}} =
             Client.catalog(client(transport, retry_delays_ms: [0, 0]))

    assert Agent.get(calls, & &1) == 3
  end

  test "one overall deadline and cancellation terminate attempts" do
    slow = fn _request ->
      Process.sleep(10)
      {:error, :timeout}
    end

    assert {:error, %Error{code: :timeout}} =
             Client.catalog(client(slow, overall_timeout_ms: 1, retry_delays_ms: [0, 0]))

    assert {:error, %Error{code: :cancelled}} =
             Client.catalog(
               client(fn _ -> flunk("transport must not run") end, cancelled?: fn -> true end)
             )
  end

  test "redirects are terminal and credentials are never sent to the location" do
    parent = self()

    transport = fn request ->
      send(parent, {:request, request})
      {:ok, %{status: 302, headers: %{"location" => "https://other.invalid/steal"}, body: ""}}
    end

    assert {:error, %Error{code: :invalid_request, retryable: false}} =
             Client.catalog(client(transport))

    assert_receive {:request, %{headers: %{"authorization" => "Bearer secret"}}}
    refute_receive {:request, _}
  end

  test "artifact checksum mismatch is terminal" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    transport = fn _request ->
      Agent.update(calls, &(&1 + 1))
      {:ok, %{status: 200, headers: %{}, body: ["bad", " bytes"]}}
    end

    ref = %SkillRef{
      source_id: "source-a",
      skill_id: "opaque/id",
      revision: "r1",
      artifact_digest: @digest
    }

    assert {:error, %Error{code: :integrity_mismatch, retryable: false}} =
             Client.artifact(client(transport), ref)

    assert Agent.get(calls, & &1) == 1
  end

  test "HTTP 410 decodes unavailable exact revision without retry" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    transport = fn _request ->
      Agent.update(calls, &(&1 + 1))
      {:ok, %{status: 410, headers: %{}, body: error_body("revision_unavailable", false)}}
    end

    assert {:error, %Error{code: :revision_unavailable, retryable: false}} =
             Client.resolve(client(transport), "opaque/id", "missing")

    assert Agent.get(calls, & &1) == 1
  end

  defp client(transport, opts \\ []) do
    Client.new!(
      Keyword.merge(
        [
          endpoint: "https://backplane.example",
          source_id: "source-a",
          access_context_id: "tenant-a",
          credential_supplier: fn -> {:ok, "secret"} end,
          transport: transport
        ],
        opts
      )
    )
  end

  defp manifest(skill_id, revision) do
    %{
      "protocol_version" => "1",
      "profile" => "backplane.skill-bundle.v1",
      "skill_id" => skill_id,
      "revision" => revision,
      "root" => "example-skill",
      "entrypoint" => "SKILL.md",
      "document_metadata" => %{"name" => "example-skill", "description" => "Example"},
      "artifact_format" => "tar+gzip",
      "artifact_digest" => @digest,
      "compressed_bytes" => 1,
      "unpacked_bytes" => 1,
      "files" => [%{"path" => "SKILL.md", "bytes" => 1, "sha256" => String.duplicate("b", 64)}],
      "required_capabilities" => []
    }
  end

  defp error_body(code, retryable) do
    JSON.encode!(%{
      "protocol_version" => "1",
      "error" => %{"code" => code, "message" => code, "retryable" => retryable, "context" => %{}}
    })
  end
end
