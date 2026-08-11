defmodule Backplane.McpProtocol.Protocol.V2026_07_28Test do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Protocol.Registry
  alias Backplane.McpProtocol.Protocol.V2026_07_28

  test "2026-07-28 is a stateless modern profile" do
    assert {:ok, profile} = Registry.profile("2026-07-28")
    assert profile == V2026_07_28.profile()
    assert profile.era == :modern
    assert profile.lifecycle == :per_request
    assert "server/discover" in profile.request_methods
    refute "initialize" in profile.request_methods
    refute "ping" in profile.request_methods
    refute "tasks/list" in profile.request_methods
    refute :tasks in profile.features
  end

  test "legacy profiles preserve initialization" do
    assert {:ok, profile} = Registry.profile("2025-11-25")
    assert profile.era == :legacy
    assert profile.lifecycle == :initialize
    assert "initialize" in profile.request_methods
  end

  test "modern top-level methods match the 2026-07-28 message unions" do
    assert MapSet.new(V2026_07_28.request_methods()) ==
             MapSet.new(~w(
               server/discover completion/complete
               prompts/get prompts/list
               resources/list resources/templates/list resources/read
               subscriptions/listen
               tools/call tools/list
             ))

    assert MapSet.new(V2026_07_28.notification_methods()) ==
             MapSet.new(~w(
               notifications/cancelled notifications/message notifications/progress
               notifications/prompts/list_changed
               notifications/resources/list_changed notifications/resources/updated
               notifications/subscriptions/acknowledged
               notifications/tools/list_changed
             ))
  end

  test "modern profile records cacheable and named HTTP methods" do
    profile = V2026_07_28.profile()

    assert MapSet.new(profile.cacheable_methods) ==
             MapSet.new(~w(
               server/discover prompts/list resources/list
               resources/templates/list resources/read tools/list
             ))

    assert MapSet.new(profile.named_methods) ==
             MapSet.new(~w(prompts/get resources/read tools/call))
  end

  test "modern profile keeps deprecated capabilities but removes their legacy RPCs" do
    profile = V2026_07_28.profile()

    assert :logging in profile.features
    assert :roots in profile.features
    assert :sampling in profile.features
    assert :elicitation in profile.features
    assert :multi_round_trip_requests in profile.features

    refute "logging/setLevel" in profile.request_methods
    refute "roots/list" in profile.request_methods
    refute "sampling/createMessage" in profile.request_methods
    refute "elicitation/create" in profile.request_methods
  end
end
