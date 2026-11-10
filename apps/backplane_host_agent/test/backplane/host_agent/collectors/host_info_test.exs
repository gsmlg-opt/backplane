defmodule Backplane.HostAgent.Collectors.HostInfoTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Collectors.HostInfo

  @ss """
  LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
  LISTEN 0 4096 [::]:22 [::]:* users:(("sshd",pid=1,fd=4))
  LISTEN 0 244 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=9,fd=5))
  LISTEN 0 511 *:80 *:*
  LISTEN 0 10 127.0.0.1:32768 0.0.0.0:* users:(("ephemeral",pid=7,fd=3))
  LISTEN 0 10 127.0.0.1:41234 0.0.0.0:* users:(("ephemeral",pid=7,fd=4))
  """

  @lsof """
  COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
  beam.smp  101 gao   10u  IPv4 0x1      0t0  TCP *:4220 (LISTEN)
  beam.smp  101 gao   11u  IPv6 0x2      0t0  TCP *:4220 (LISTEN)
  postgres  202 gao    7u  IPv6 0x3      0t0  TCP [::1]:5432 (LISTEN)
  postgres  202 gao    8u  IPv4 0x4      0t0  TCP 127.0.0.1:5432 (LISTEN)
  Google\\x20Chrome 303 gao 9u IPv4 0x5 0t0 TCP 127.0.0.1:9222 (LISTEN)
  rapportd  404 gao    4u  IPv4 0x6      0t0  TCP *:49152 (LISTEN)
  Code      505 gao    5u  IPv4 0x7      0t0  TCP 127.0.0.1:41234 (LISTEN)
  """

  @ifaddrs {:ok,
            [
              {~c"lo0", [flags: [:up, :loopback], addr: {127, 0, 0, 1}]},
              {~c"lo0", [addr: {0, 0, 0, 0, 0, 0, 0, 1}]},
              {~c"en0",
               [
                 flags: [:up, :broadcast],
                 hwaddr: [1, 2, 3, 4, 5, 6],
                 addr: {192, 168, 1, 20},
                 addr: {0xFE80, 0, 0, 0, 1, 2, 3, 4},
                 addr: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 5}
               ]},
              {~c"en1", [flags: [:up], addr: {169, 254, 3, 4}, addr: {10, 0, 0, 2}]},
              {~c"docker0", [flags: [:up], addr: {172, 17, 0, 1}]},
              {~c"br-1a2b", [flags: [:up], addr: {172, 18, 0, 1}]},
              {~c"veth9", [flags: [:up], addr: {172, 19, 0, 1}]},
              {~c"utun3", [flags: [:up], addr: {10, 8, 0, 1}]},
              {~c"bridge100", [flags: [:up], addr: {192, 168, 64, 1}]},
              {~c"vmnet8", [flags: [:up], addr: {192, 168, 65, 1}]},
              {~c"awdl0", [flags: [:up], addr: {0xFE80, 0, 0, 0, 9, 9, 9, 9}]},
              {~c"llw0", [flags: [:up], addr: {192, 168, 66, 1}]},
              {~c"lo1", [flags: [:up], addr: {10, 9, 9, 9}]}
            ]}

  defp env(os, result, extra \\ %{}) do
    runner = fn
      "uname", ["-sr"], _ -> {:ok, "Linux 6.1.0\n"}
      _cmd, _args, _ -> result
    end

    Map.merge(
      %{
        runner: runner,
        os: os,
        home: "/h",
        hostname: {:ok, ~c"box"},
        ifaddrs: @ifaddrs
      },
      extra
    )
  end

  defp item(snapshots) do
    assert [%{collector: "host", unit: "local", items: [item]} = snap] = snapshots
    {snap, item}
  end

  test "config_key is :host" do
    assert HostInfo.config_key() == :host
  end

  test "linux: hostname, os, filtered sorted addresses, deduped listening" do
    test_pid = self()

    runner = fn cmd, args, _ ->
      send(test_pid, {:ran, cmd, args})

      case cmd do
        "uname" -> {:ok, "Linux 6.1.0-18-amd64\n"}
        "ss" -> {:ok, @ss}
      end
    end

    {snap, item} = item(HostInfo.collect(%{}, env(:linux, nil, %{runner: runner})))

    assert_received {:ran, "uname", ["-sr"]}
    assert_received {:ran, "ss", ["-ltnpH"]}
    assert snap.complete

    assert item == %{
             "hostname" => "box",
             "os" => "Linux 6.1.0-18-amd64",
             "addresses" => ["10.0.0.2", "192.168.1.20"],
             "listening" => [
               %{"port" => 22, "process" => "sshd"},
               %{"port" => 80, "process" => nil},
               %{"port" => 5432, "process" => "postgres"}
             ]
           }
  end

  test "darwin: parses lsof, collapses IPv4/IPv6 duplicates, keeps escaped names" do
    test_pid = self()

    runner = fn cmd, args, _ ->
      send(test_pid, {:ran, cmd, args})

      case cmd do
        "uname" -> {:ok, "Darwin 25.0.0\n"}
        "lsof" -> {:ok, @lsof}
      end
    end

    {snap, item} = item(HostInfo.collect(%{}, env(:darwin, nil, %{runner: runner})))

    assert_received {:ran, "lsof", ["-w", "-nP", "-iTCP", "-sTCP:LISTEN"]}
    assert snap.complete
    assert item["os"] == "Darwin 25.0.0"

    assert item["listening"] == [
             %{"port" => 4220, "process" => "beam.smp"},
             %{"port" => 5432, "process" => "postgres"},
             %{"port" => 9222, "process" => "Google\\x20Chrome"},
             %{"port" => 41234, "process" => "Code"}
           ]
  end

  test "listening order does not change the snapshot" do
    reversed = @ss |> String.split("\n", trim: true) |> Enum.reverse() |> Enum.join("\n")

    assert HostInfo.collect(%{}, env(:linux, {:ok, @ss})) ==
             HostInfo.collect(%{}, env(:linux, {:ok, reversed}))
  end

  test "same port with different processes yields one entry each, sorted by process" do
    out = """
    LISTEN 0 1 0.0.0.0:8080 0.0.0.0:* users:(("zed",pid=1,fd=3))
    LISTEN 0 1 [::]:8080 [::]:* users:(("alpha",pid=2,fd=3))
    """

    {_snap, item} = item(HostInfo.collect(%{}, env(:linux, {:ok, out})))

    assert item["listening"] == [
             %{"port" => 8080, "process" => "alpha"},
             %{"port" => 8080, "process" => "zed"}
           ]
  end

  test "a failed listening scan yields no host snapshot" do
    for os <- [:linux, :darwin],
        result <- [
          {:error, {:exit, 1}},
          {:error, {:exit, 2, ""}},
          {:error, :timeout},
          {:error, :not_found}
        ] do
      assert HostInfo.collect(%{}, env(os, result)) == [], "#{os} #{inspect(result)}"
    end
  end

  test "lsof exit 1 with empty output means no listeners" do
    {snap, item} = item(HostInfo.collect(%{}, env(:darwin, {:error, {:exit, 1, ""}})))
    assert snap.complete
    assert item["listening"] == []

    assert HostInfo.collect(%{}, env(:darwin, {:error, {:exit, 1, "lsof: oops\n"}})) == []
  end

  test "lsof is asked for its output on failure" do
    test_pid = self()

    runner = fn cmd, args, opts ->
      send(test_pid, {:ran, cmd, args, opts})
      {:ok, ""}
    end

    HostInfo.collect(%{}, env(:darwin, nil, %{runner: runner}))
    assert_received {:ran, "lsof", _, opts}
    assert opts[:output_on_error]
  end

  test "unparseable listening line marks the snapshot incomplete" do
    {snap, item} = item(HostInfo.collect(%{}, env(:linux, {:ok, "garbage\n" <> @ss})))

    refute snap.complete
    assert length(item["listening"]) == 3
  end

  test "other os omits the listening key" do
    {snap, item} = item(HostInfo.collect(%{}, env(:other, nil)))

    assert snap.complete
    refute Map.has_key?(item, "listening")
    assert item["addresses"] == ["10.0.0.2", "192.168.1.20"]
  end

  test "uname failure falls back to :os.type" do
    runner = fn
      "uname", _, _ -> {:error, :not_found}
      "ss", _, _ -> {:ok, @ss}
    end

    {snap, item} = item(HostInfo.collect(%{}, env(:linux, nil, %{runner: runner})))

    assert snap.complete
    assert item["os"] == inspect(:os.type())
  end

  test "defaults to the real hostname and interfaces" do
    runner = fn
      "uname", _, _ -> {:error, :not_found}
      _, _, _ -> {:ok, ""}
    end

    {_snap, item} =
      item(HostInfo.collect(%{}, %{runner: runner, os: :linux, home: "/h"}))

    assert is_binary(item["hostname"])
    assert is_list(item["addresses"])
  end
end
