defmodule Backplane.Skills.HostsTest do
  use Backplane.DataCase, async: true

  alias Backplane.Skills.Hosts

  describe "hosts" do
    test "creates a host with a hashed token and verifies the token" do
      assert {:ok, host, token} =
               Hosts.create_host(%{
                 "name" => "t430",
                 "hostname" => "t430.local",
                 "targets" => [
                   %{
                     "name" => "agents",
                     "runtime" => "agent-skills",
                     "path" => "/tmp/skills",
                     "enabled" => true
                   }
                 ],
                 "metadata" => %{"os" => "nixos"}
               })

      assert is_binary(token)
      assert String.starts_with?(token, "bha_")
      refute token == host.token_hash
      assert Bcrypt.verify_pass(token, host.token_hash)
      assert {:ok, verified} = Hosts.verify_token(token)
      assert verified.id == host.id
      assert verified.targets["agents"]["runtime"] == "agent-skills"
    end

    test "rejects an invalid token" do
      assert :error = Hosts.verify_token("missing-token")
    end

    test "verify_token touches last_seen_at" do
      assert {:ok, host, token} = Hosts.create_host(%{"name" => "t430"})
      assert is_nil(host.last_seen_at)

      assert {:ok, verified} = Hosts.verify_token(token)
      assert verified.id == host.id
      assert %DateTime{} = verified.last_seen_at

      assert %DateTime{} = Hosts.get_host(host.id).last_seen_at
    end

    test "lists and gets hosts created with atom-key targets" do
      assert {:ok, first, _token} =
               Hosts.create_host(%{
                 name: "b-host",
                 targets: [%{name: "agents", runtime: "agent-skills"}]
               })

      assert {:ok, _second, _token} = Hosts.create_host(%{name: "a-host"})

      assert Hosts.get_host(first.id).targets["agents"]["runtime"] == "agent-skills"
      assert Enum.map(Hosts.list_hosts(), & &1.name) == ["a-host", "b-host"]
    end

    test "heartbeat updates last_seen_at, status, targets, and metadata" do
      assert {:ok, host, _token} = Hosts.create_host(%{"name" => "t430"})

      assert {:ok, updated} =
               Hosts.heartbeat(host, %{
                 "hostname" => "t430",
                 "agent_version" => "0.1.0",
                 "targets" => [
                   %{
                     "name" => "agents",
                     "runtime" => "agent-skills",
                     "path" => "/tmp/skills",
                     "enabled" => true
                   }
                 ],
                 "metadata" => %{"arch" => "x86_64"}
               })

      assert updated.status == "online"
      assert updated.agent_version == "0.1.0"
      assert updated.targets["agents"]["enabled"] == true
      assert updated.metadata["arch"] == "x86_64"
      assert %DateTime{} = updated.last_seen_at
    end
  end
end
