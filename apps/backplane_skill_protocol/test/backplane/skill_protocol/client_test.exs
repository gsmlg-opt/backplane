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

  test "catalog negotiates and decodes optional argument hints without weakening strict fields" do
    parent = self()

    transport = fn request ->
      send(parent, {:request, request})

      {:ok,
       %{
         status: 200,
         headers: %{},
         body:
           JSON.encode!(%{
             "protocol_version" => "1",
             "data" => [
               descriptor_map("with-hint", "FILE"),
               descriptor_map("null-hint", nil),
               Map.delete(descriptor_map("legacy", nil), "argument_hint")
             ],
             "next_cursor" => nil
           })
       }}
    end

    assert {:ok,
            %{
              data: [
                %Descriptor{argument_hint: "FILE"},
                %Descriptor{argument_hint: nil},
                %Descriptor{argument_hint: nil}
              ]
            }} = Client.catalog(client(transport), fields: [:argument_hint])

    assert_receive {:request, %{url: url}}
    assert URI.decode_query(URI.parse(url).query) == %{"fields" => "argument_hint"}

    for invalid <- [123, [], %{}] do
      body =
        JSON.encode!(%{
          "protocol_version" => "1",
          "data" => [descriptor_map("invalid", invalid)],
          "next_cursor" => nil
        })

      assert {:error, %Error{code: :invalid_request}} =
               Client.catalog(client(fn _ -> {:ok, %{status: 200, headers: %{}, body: body}} end))
    end

    unknown = Map.put(descriptor_map("unknown", nil), "unexpected", true)

    assert {:error, %Error{code: :invalid_request}} =
             Client.catalog(
               client(fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    headers: %{},
                    body:
                      JSON.encode!(%{
                        "protocol_version" => "1",
                        "data" => [unknown],
                        "next_cursor" => nil
                      })
                  }}
               end)
             )
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

  test "ordinary retry succeeds and terminal errors do not retry" do
    parent = self()
    retry_counter = :atomics.new(1, [])

    retrying = fn _request ->
      attempt = :atomics.add_get(retry_counter, 1, 1)
      send(parent, {:attempt, attempt})

      if attempt == 1 do
        {:ok, %{status: 503, headers: %{}, body: error_body("temporarily_unavailable", true)}}
      else
        {:ok, %{status: 200, headers: %{}, body: catalog_body()}}
      end
    end

    assert {:ok, %{data: []}} = Client.catalog(client(retrying, retry_delays_ms: [0]))
    assert_receive {:attempt, 1}
    assert_receive {:attempt, 2}

    terminal_counter = :atomics.new(1, [])

    terminal = fn _request ->
      :atomics.add_get(terminal_counter, 1, 1)
      {:ok, %{status: 403, headers: %{}, body: error_body("forbidden", false)}}
    end

    assert {:error, %Error{code: :forbidden, retryable: false}} =
             Client.catalog(client(terminal, retry_delays_ms: [0, 0]))

    assert :atomics.get(terminal_counter, 1) == 1
  end

  for cancellation_scope <- [:client, :call] do
    test "#{cancellation_scope} cancellation interrupts retry backoff" do
      parent = self()
      cancelled = :atomics.new(1, [])
      calls = :atomics.new(1, [])

      transport = fn _request ->
        attempt = :atomics.add_get(calls, 1, 1)

        if attempt == 1 do
          {:ok, %{status: 503, headers: %{}, body: error_body("temporarily_unavailable", true)}}
        else
          flunk("a cancelled backoff must not start another request")
        end
      end

      sleep = fn interval ->
        send(parent, {:backoff_started, self()})
        Process.sleep(interval)
      end

      cancellation = fn -> :atomics.get(cancelled, 1) == 1 end

      {client_opts, call_opts} =
        case unquote(cancellation_scope) do
          :client -> {[cancelled?: cancellation], []}
          :call -> {[], [cancelled?: cancellation]}
        end

      task =
        Task.async(fn ->
          Client.catalog(
            client(
              transport,
              Keyword.merge(
                [retry_delays_ms: [5_000], overall_timeout_ms: 10_000, sleep: sleep],
                client_opts
              )
            ),
            call_opts
          )
        end)

      task_pid = task.pid
      assert_receive {:backoff_started, ^task_pid}, 500
      :atomics.put(cancelled, 1, 1)
      started_at = System.monotonic_time(:millisecond)

      assert {:error, %Error{code: :cancelled}} = Task.await(task, 500)
      assert System.monotonic_time(:millisecond) - started_at < 250
      assert :atomics.get(calls, 1) == 1
    end
  end

  test "retry backoff uses the original absolute deadline" do
    now = :atomics.new(1, [])
    calls = :atomics.new(1, [])

    transport = fn _request ->
      :atomics.add_get(calls, 1, 1)
      {:ok, %{status: 503, headers: %{}, body: error_body("temporarily_unavailable", true)}}
    end

    clock = fn -> :atomics.get(now, 1) end
    sleep = fn interval -> :atomics.add_get(now, 1, interval) end

    assert {:error, %Error{code: :timeout}} =
             Client.catalog(
               client(transport,
                 clock: clock,
                 sleep: sleep,
                 overall_timeout_ms: 50,
                 retry_delays_ms: [50]
               )
             )

    assert :atomics.get(calls, 1) == 1
    assert :atomics.get(now, 1) == 0
  end

  test "cancellation before an attempt does not start transport work" do
    assert {:error, %Error{code: :cancelled}} =
             Client.catalog(
               client(fn _ -> flunk("transport must not run") end, cancelled?: fn -> true end)
             )
  end

  test "an active request uses the operation's absolute deadline" do
    parent = self()
    now = :atomics.new(1, [])

    stalled = fn _request ->
      send(parent, {:started, self()})

      receive do
        :never -> {:ok, %{status: 200, headers: %{}, body: ""}}
      end
    end

    task =
      Task.async(fn ->
        Client.catalog(
          client(stalled,
            clock: fn -> :atomics.get(now, 1) end,
            overall_timeout_ms: 100
          )
        )
      end)

    assert_receive {:started, worker}, 500
    worker_monitor = Process.monitor(worker)
    :atomics.put(now, 1, 100)

    assert {:error, %Error{code: :timeout}} = Task.await(task, 500)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
  end

  test "explicit cancellation terminates and confirms a blocking transport worker" do
    parent = self()

    {:ok, flag} = Agent.start_link(fn -> false end)

    cancelled = fn _request ->
      send(parent, {:cancel_started, self()})

      receive do
        :never -> {:ok, %{status: 200, headers: %{}, body: ""}}
      end
    end

    task =
      Task.async(fn ->
        Client.catalog(
          client(cancelled,
            cancelled?: fn -> Agent.get(flag, & &1) end,
            overall_timeout_ms: 1_000
          )
        )
      end)

    assert_receive {:cancel_started, cancel_worker}, 100
    cancel_monitor = Process.monitor(cancel_worker)
    Agent.update(flag, fn _ -> true end)
    assert {:error, %Error{code: :cancelled}} = Task.await(task, 1_000)
    assert_receive {:DOWN, ^cancel_monitor, :process, ^cancel_worker, :killed}, 500
  end

  test "normal caller exit stops active transport work" do
    parent = self()

    transport = fn _request ->
      send(parent, {:owner_request_started, self()})

      receive do
        :never -> {:ok, %{status: 200, headers: %{}, body: catalog_body()}}
      end
    end

    caller =
      spawn(fn ->
        cancelled? = fn ->
          receive do
            :exit_normally -> exit(:normal)
          after
            0 -> false
          end
        end

        Client.catalog(
          client(transport,
            cancelled?: cancelled?,
            max_attempts: 1,
            overall_timeout_ms: 10_000
          )
        )
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:owner_request_started, worker}, 500
    worker_monitor = Process.monitor(worker)
    send(caller, :exit_normally)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
  end

  test "abnormal caller termination stops active transport work" do
    parent = self()

    transport = fn _request ->
      send(parent, {:owner_request_started, self()})

      receive do
        :never -> {:ok, %{status: 200, headers: %{}, body: catalog_body()}}
      end
    end

    caller =
      spawn(fn ->
        Client.catalog(client(transport, max_attempts: 1, overall_timeout_ms: 10_000))
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:owner_request_started, worker}, 500
    worker_monitor = Process.monitor(worker)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
  end

  test "transport crashes are isolated from the caller" do
    assert {:error, %Error{code: :temporarily_unavailable, retryable: true}} =
             Client.catalog(client(fn _request -> exit(:transport_boom) end, max_attempts: 1))

    assert Process.alive?(self())
  end

  test "completed operations leave no operation monitors or late replies" do
    parent = self()
    body = catalog_body()

    caller =
      spawn(fn ->
        initial_monitors = Process.info(self(), :monitors)

        for index <- 1..20 do
          transport = fn _request ->
            send(parent, {:completed_worker, index, self()})
            {:ok, %{status: 200, headers: %{}, body: body}}
          end

          {:ok, %{data: []}} = Client.catalog(client(transport))
        end

        send(parent, {
          :operation_cleanup,
          initial_monitors,
          Process.info(self(), :monitors),
          Process.info(self(), :messages)
        })
      end)

    caller_monitor = Process.monitor(caller)

    workers =
      for index <- 1..20 do
        assert_receive {:completed_worker, ^index, worker}, 500
        worker
      end

    assert_receive {:operation_cleanup, initial_monitors, final_monitors, {:messages, []}}, 500
    assert final_monitors == initial_monitors
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 500

    for worker <- workers do
      monitor = Process.monitor(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :noproc}, 500
    end
  end

  test "a live transport worker completes normally under a preinstalled monitor" do
    parent = self()

    transport = fn _request ->
      send(parent, {:held_worker, self()})

      receive do
        :complete -> {:ok, %{status: 200, headers: %{}, body: catalog_body()}}
      end
    end

    caller =
      spawn(fn -> send(parent, {:held_result, Client.catalog(client(transport))}) end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:held_worker, worker}, 500
    worker_monitor = Process.monitor(worker)
    send(worker, :complete)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 500
    assert_receive {:held_result, {:ok, %{data: []}}}, 500
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 500
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

  defp catalog_body do
    JSON.encode!(%{"protocol_version" => "1", "data" => [], "next_cursor" => nil})
  end

  defp descriptor_map(skill_id, argument_hint) do
    %{
      "skill_id" => skill_id,
      "name" => skill_id,
      "description" => "Example",
      "revision" => "rev-1",
      "artifact_digest" => @digest,
      "publication_status" => "ready",
      "argument_hint" => argument_hint
    }
  end
end
