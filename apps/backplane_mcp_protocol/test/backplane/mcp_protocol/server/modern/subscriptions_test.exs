defmodule Backplane.McpProtocol.Server.Modern.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Server.Modern.Subscriptions

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  setup do
    hub = start_supervised!({Subscriptions, []})
    %{hub: hub}
  end

  test "validates the frozen filter and acknowledges only the capability intersection", %{hub: hub} do
    context =
      subscription_context("listen-1", %{
        "toolsListChanged" => true,
        "promptsListChanged" => false,
        "resourcesListChanged" => true,
        "resourceSubscriptions" => ["file:///a", "file:///b"],
        "futureFilter" => %{"ignored" => true}
      })

    assert {:ok, ref} = Subscriptions.subscribe(hub, self(), context)

    assert_receive {:mcp_subscription, ^ref,
                    %{
                      "jsonrpc" => "2.0",
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "notifications" => %{
                          "toolsListChanged" => true,
                          "resourceSubscriptions" => ["file:///a", "file:///b"]
                        },
                        "_meta" => %{
                          "trace" => "request-meta",
                          @subscription_id_key => "listen-1"
                        }
                      }
                    }}
  end

  test "prefers canonical string capability keys and preserves duplicate resource URIs", %{hub: hub} do
    context =
      subscription_context("capability-precedence", %{
        "toolsListChanged" => true,
        "resourceSubscriptions" => ["file:///same", "file:///same"]
      })

    context = %{
      context
      | server_capabilities: %{
          "tools" => %{"listChanged" => false, :listChanged => true},
          :tools => %{list_changed: true},
          "resources" => %{"subscribe" => true},
          :resources => %{subscribe: false}
        }
    }

    assert {:ok, ref} = Subscriptions.subscribe(hub, self(), context)

    assert_receive {:mcp_subscription, ^ref,
                    %{
                      "params" => %{
                        "notifications" => %{
                          "resourceSubscriptions" => ["file:///same", "file:///same"]
                        }
                      }
                    }}
  end

  test "rejects missing notifications and every present known field with the wrong type", %{hub: hub} do
    invalid_notifications = [
      :missing,
      [],
      %{"toolsListChanged" => "true"},
      %{"promptsListChanged" => 1},
      %{"resourcesListChanged" => nil},
      %{"resourceSubscriptions" => "file:///a"},
      %{"resourceSubscriptions" => ["file:///a", 2]}
    ]

    for notifications <- invalid_notifications do
      context =
        case notifications do
          :missing -> subscription_context("bad", :missing)
          value -> subscription_context("bad", value)
        end

      assert {:error, %Error{code: -32_602, reason: :invalid_params}} =
               Subscriptions.subscribe(hub, self(), context)
    end

    refute_receive {:mcp_subscription, _, _}
  end

  test "filters methods and exact resource URIs while preserving and stamping event metadata", %{hub: hub} do
    assert {:ok, ref} =
             Subscriptions.subscribe(
               hub,
               self(),
               subscription_context("listen-events", %{
                 "toolsListChanged" => true,
                 "resourceSubscriptions" => ["file:///exact"]
               })
             )

    assert_receive {:mcp_subscription, ^ref, %{"method" => "notifications/subscriptions/acknowledged"}}

    ignored = [
      notification("notifications/prompts/list_changed", %{}),
      notification("notifications/resources/list_changed", %{}),
      notification("notifications/resources/updated", %{"uri" => "file:///exact/child"}),
      notification("notifications/message", %{"data" => "ignored"})
    ]

    Enum.each(ignored, &assert(:ok == Subscriptions.publish(hub, &1)))
    refute_receive {:mcp_subscription, ^ref, _}

    event =
      notification("notifications/resources/updated", %{
        "uri" => "file:///exact",
        "value" => 7,
        "_meta" => %{"trace" => "event-meta"}
      })

    assert :ok = Subscriptions.publish(hub, event)

    assert_receive {:mcp_subscription, ^ref,
                    %{
                      "jsonrpc" => "2.0",
                      "method" => "notifications/resources/updated",
                      "params" => %{
                        "uri" => "file:///exact",
                        "value" => 7,
                        "_meta" => %{
                          "trace" => "event-meta",
                          @subscription_id_key => "listen-events"
                        }
                      }
                    }}

    assert :ok = Subscriptions.publish(hub, notification("notifications/tools/list_changed", %{"revision" => 3}))

    assert_receive {:mcp_subscription, ^ref,
                    %{
                      "method" => "notifications/tools/list_changed",
                      "params" => %{
                        "revision" => 3,
                        "_meta" => %{@subscription_id_key => "listen-events"}
                      }
                    }}
  end

  test "normalizes parameterless list-change notifications before stamping metadata", %{hub: hub} do
    assert {:ok, ref} =
             Subscriptions.subscribe(
               hub,
               self(),
               subscription_context("parameterless", %{"toolsListChanged" => true})
             )

    assert_receive {:mcp_subscription, ^ref, %{"method" => "notifications/subscriptions/acknowledged"}}

    assert :ok =
             Subscriptions.publish(hub, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/tools/list_changed"
             })

    assert_receive {:mcp_subscription, ^ref,
                    %{
                      "method" => "notifications/tools/list_changed",
                      "params" => %{
                        "_meta" => %{@subscription_id_key => "parameterless"}
                      }
                    }}
  end

  test "keeps equal subscriptions distinct, fans out in isolation, and never replays", %{hub: hub} do
    event = notification("notifications/tools/list_changed", %{"revision" => 1})
    assert :ok = Subscriptions.publish(hub, event)

    context = subscription_context(42, %{"toolsListChanged" => true})
    assert {:ok, first} = Subscriptions.subscribe(hub, self(), context)
    assert {:ok, second} = Subscriptions.subscribe(hub, self(), context)
    refute first == second

    assert_receive {:mcp_subscription, ^first, %{"method" => "notifications/subscriptions/acknowledged"}}
    assert_receive {:mcp_subscription, ^second, %{"method" => "notifications/subscriptions/acknowledged"}}
    refute_receive {:mcp_subscription, _, %{"method" => "notifications/tools/list_changed"}}

    assert :ok = Subscriptions.publish(hub, event)
    assert_receive {:mcp_subscription, ^first, %{"params" => %{"_meta" => %{@subscription_id_key => 42}}}}

    assert_receive {:mcp_subscription, ^second, %{"params" => %{"_meta" => %{@subscription_id_key => 42}}}}

    assert :ok = Subscriptions.unsubscribe(hub, first)
    assert :ok = Subscriptions.unsubscribe(hub, first)
    assert :ok = Subscriptions.publish(hub, event)
    refute_receive {:mcp_subscription, ^first, _}
    assert_receive {:mcp_subscription, ^second, _}
  end

  test "removes all subscriptions when a monitored subscriber exits", %{hub: hub} do
    parent = self()

    subscriber =
      spawn(fn ->
        {:ok, ref} =
          Subscriptions.subscribe(
            hub,
            self(),
            subscription_context("monitored", %{"toolsListChanged" => true})
          )

        send(parent, {:subscribed, ref})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:subscribed, ref}
    monitor = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :normal}
    await_subscription_count(hub, 0)

    assert :ok = Subscriptions.publish(hub, notification("notifications/tools/list_changed", %{}))
    refute_receive {:mcp_subscription, ^ref, _}
  end

  test "graceful close sends one stamped complete result and clears every subscription", %{hub: hub} do
    assert {:ok, ref} =
             Subscriptions.subscribe(
               hub,
               self(),
               subscription_context("closing", %{"toolsListChanged" => true})
             )

    assert_receive {:mcp_subscription, ^ref, %{"method" => "notifications/subscriptions/acknowledged"}}
    assert :ok = Subscriptions.close(hub)

    assert_receive {:mcp_subscription, ^ref,
                    %{
                      "jsonrpc" => "2.0",
                      "id" => "closing",
                      "result" => %{
                        "resultType" => "complete",
                        "_meta" => %{
                          @subscription_id_key => "closing",
                          @server_info_key => %{"name" => "subscription-test", "version" => "1.0.0"}
                        }
                      }
                    }}

    await_subscription_count(hub, 0)
    assert :ok = Subscriptions.unsubscribe(hub, ref)
  end

  defp subscription_context(id, notifications) do
    params =
      then(
        %{
          "_meta" => %{
            "trace" => "request-meta",
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        },
        fn params ->
          if notifications == :missing, do: params, else: Map.put(params, "notifications", notifications)
        end
      )

    %{
      request: %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "subscriptions/listen",
        "params" => params
      },
      server_capabilities: %{
        "tools" => %{"listChanged" => true},
        "prompts" => %{"listChanged" => false},
        "resources" => %{"listChanged" => false, "subscribe" => true}
      },
      server_info: %{"name" => "subscription-test", "version" => "1.0.0"}
    }
  end

  defp notification(method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp await_subscription_count(hub, expected, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_subscription_count(hub, expected, deadline)
  end

  defp do_await_subscription_count(hub, expected, deadline) do
    state = :sys.get_state(hub)

    cond do
      map_size(state.subscriptions) == expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{expected} subscriptions: #{inspect(state)}")

      true ->
        receive do
        after
          1 -> do_await_subscription_count(hub, expected, deadline)
        end
    end
  end
end
