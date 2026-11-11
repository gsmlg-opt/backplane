defmodule Backplane.Memory.HostSnapshots.FactsTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.HostSnapshots.Facts

  @git %{
    "path" => "/srv/app",
    "repository_id" => "github.com/o/r",
    "branch" => "main",
    "head" => %{
      "commit" => "abcdef123456",
      "subject" => "fix x",
      "committed_at" => "2026-11-10T01:00:00Z"
    }
  }

  describe "facts/3" do
    test "git item yields checkout and head facts" do
      assert [checkout, head] = Facts.facts("db02", "git", @git)

      assert checkout.property == "git_checkout"
      assert checkout.content == "Git checkout of github.com/o/r at db02:/srv/app (branch main)."
      assert checkout.subject_keys == ["host:db02", "path:/srv/app", "repo:github.com/o/r"]
      assert checkout.slot == "git_checkout|host:db02,path:/srv/app,repo:github.com/o/r"

      assert checkout.subjects == [
               %{"type" => "host", "key" => "db02"},
               %{"type" => "path", "key" => "/srv/app"},
               %{"type" => "repo", "key" => "github.com/o/r"}
             ]

      assert head.property == "git_head"

      assert head.content ==
               "Latest commit in db02:/srv/app: abcdef1 \"fix x\" (2026-11-10T01:00:00Z)."

      assert head.slot == "git_head|host:db02,path:/srv/app,repo:github.com/o/r"
    end

    test "git item without remote, branch, or head uses fallbacks" do
      item = %{"path" => "/w/x", "repository_id" => nil, "branch" => nil, "head" => nil}
      assert [fact] = Facts.facts("h", "git", item)

      assert fact.content ==
               "Git checkout of a local repository (no remote) at h:/w/x (branch detached)."

      assert fact.subject_keys == ["host:h", "path:/w/x"]
    end

    test "docker item" do
      item = %{
        "name" => "web",
        "image" => "nginx:1",
        "state" => "running",
        "ports" => ["80", "443"]
      }

      assert [f] = Facts.facts("h", "docker", item)
      assert f.property == "docker_container"

      assert f.content ==
               "Docker container web on h: image nginx:1, state running, ports 80, 443."

      assert f.subject_keys == ["host:h", "service:web"]
      assert f.slot == "docker_container|host:h,service:web"

      assert [%{content: c}] = Facts.facts("h", "docker", %{item | "ports" => []})
      assert c == "Docker container web on h: image nginx:1, state running, ports none."
    end

    test "systemd item" do
      assert [f] =
               Facts.facts("h", "systemd", %{"name" => "sshd.service", "description" => "OpenSSH"})

      assert f.property == "systemd_service"
      assert f.content == "systemd service sshd.service runs on h: OpenSSH."
      assert f.subject_keys == ["host:h", "service:sshd.service"]
    end

    test "launchd item" do
      assert [f] = Facts.facts("h", "launchd", %{"label" => "com.x.y"})
      assert f.property == "launchd_job"
      assert f.content == "launchd job com.x.y is loaded on h."
      assert f.subject_keys == ["host:h", "service:com.x.y"]
    end

    test "host item yields four facts" do
      item = %{
        "hostname" => "db02.local",
        "os" => "Linux 6.1",
        "addresses" => ["10.0.0.2", "10.0.0.3"],
        "listening" => [%{"port" => 22, "process" => "sshd"}, %{"port" => 80, "process" => nil}]
      }

      facts = Facts.facts("db02", "host", item)

      assert Enum.map(facts, & &1.property) == [
               "os",
               "hostname",
               "ip_addresses",
               "listening_ports"
             ]

      by = Map.new(facts, &{&1.property, &1})
      assert by["os"].content == "db02 runs Linux 6.1."
      assert by["hostname"].content == "db02 has hostname db02.local."
      assert by["ip_addresses"].content == "db02 IP addresses: 10.0.0.2, 10.0.0.3."
      assert by["listening_ports"].content == "db02 listens on TCP ports: 22 (sshd), 80."
      assert by["os"].subject_keys == ["host:db02"]
      assert by["os"].slot == "os|host:db02"
    end
  end

  describe "facts/4 with a host label" do
    test "content uses the label, subjects and slots keep the host id" do
      assert [checkout, head] = Facts.facts("uuid-1", "git", @git, "db02")
      assert checkout.content == "Git checkout of github.com/o/r at db02:/srv/app (branch main)."
      assert head.content =~ "Latest commit in db02:/srv/app:"
      assert checkout.subject_keys == ["host:uuid-1", "path:/srv/app", "repo:github.com/o/r"]

      assert [f] = Facts.facts("uuid-1", "launchd", %{"label" => "com.x.y"}, "db02")
      assert f.content == "launchd job com.x.y is loaded on db02."
      assert f.slot == "launchd_job|host:uuid-1,service:com.x.y"

      assert [f] =
               Facts.facts(
                 "uuid-1",
                 "docker",
                 %{"name" => "web", "image" => "i", "state" => "running", "ports" => []},
                 "db02"
               )

      assert f.content == "Docker container web on db02: image i, state running, ports none."

      host = %{"hostname" => "db02.local", "os" => "Linux", "addresses" => [], "listening" => []}
      by = "uuid-1" |> Facts.facts("host", host, "db02") |> Map.new(&{&1.property, &1.content})
      assert by["os"] == "db02 runs Linux."
      assert by["hostname"] == "db02 has hostname db02.local."
    end

    test "a nil label falls back to the host id" do
      assert Facts.facts("h", "git", @git, nil) == Facts.facts("h", "git", @git)
    end

    test "systemd service with a blank description has no trailing colon" do
      for description <- ["", "  ", nil] do
        item = %{"name" => "x.service", "description" => description}
        assert [f] = Facts.facts("uuid-1", "systemd", item, "db02")
        assert f.content == "systemd service x.service runs on db02."
      end
    end

    test "host item without a listening key yields no listening_ports fact" do
      item = %{"hostname" => "h.local", "os" => "Plan 9", "addresses" => ["10.0.0.2"]}

      assert "h" |> Facts.facts("host", item) |> Enum.map(& &1.property) ==
               ["os", "hostname", "ip_addresses"]
    end
  end

  describe "item_key/2" do
    test "per collector" do
      assert Facts.item_key("git", @git) == "/srv/app"
      assert Facts.item_key("docker", %{"name" => "web"}) == "web"
      assert Facts.item_key("systemd", %{"name" => "s"}) == "s"
      assert Facts.item_key("launchd", %{"label" => "l"}) == "l"
      assert Facts.item_key("host", %{"hostname" => "h"}) == "host"
    end
  end

  describe "validate/1" do
    test "accepts a valid payload" do
      payload = %{"collector" => "git", "unit" => "/srv", "complete" => true, "items" => [@git]}

      assert {:ok, %{collector: "git", unit: "/srv", complete: true, items: [@git]}} =
               Facts.validate(payload)
    end

    test "rejects bad payloads" do
      ok = %{"collector" => "docker", "unit" => "local", "complete" => false, "items" => []}
      assert {:ok, _} = Facts.validate(ok)
      assert {:error, :unknown_collector} = Facts.validate(%{ok | "collector" => "nope"})
      assert {:error, :unknown_collector} = Facts.validate(%{})
      assert {:error, :invalid_unit} = Facts.validate(%{ok | "unit" => "  "})
      assert {:error, :invalid_unit} = Facts.validate(%{ok | "unit" => nil})
      assert {:error, :invalid_complete} = Facts.validate(%{ok | "complete" => "yes"})
      assert {:error, :invalid_items} = Facts.validate(%{ok | "items" => %{}})
      assert {:error, :invalid_item} = Facts.validate(%{ok | "items" => [%{"image" => "x"}]})
      assert {:error, :invalid_item} = Facts.validate(%{ok | "items" => ["str"]})
    end

    test "optional host_label and unscanned" do
      ok = %{"collector" => "git", "unit" => "/srv", "complete" => true, "items" => []}

      assert {:ok, %{host_label: nil, unscanned: []}} = Facts.validate(ok)

      assert {:ok, %{host_label: "db02", unscanned: ["/srv/a", "/srv/b"]}} =
               Facts.validate(
                 Map.merge(ok, %{"host_label" => "db02", "unscanned" => ["/srv/b", "/srv/a"]})
               )

      assert {:error, :invalid_host_label} = Facts.validate(Map.put(ok, "host_label", " "))
      assert {:error, :invalid_host_label} = Facts.validate(Map.put(ok, "host_label", 1))
      assert {:error, :invalid_unscanned} = Facts.validate(Map.put(ok, "unscanned", "/srv"))
      assert {:error, :invalid_unscanned} = Facts.validate(Map.put(ok, "unscanned", [1]))
    end
  end
end
