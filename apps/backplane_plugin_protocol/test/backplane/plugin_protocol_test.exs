defmodule Backplane.PluginProtocolTest do
  use ExUnit.Case, async: true
  alias Backplane.PluginProtocol

  defp manifest(extra \\ %{}),
    do:
      JSON.encode!(
        Map.merge(
          %{
            "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
            "name" => "acme.tools"
          },
          extra
        )
      )

  defp skill(name \\ "summarize"),
    do:
      "---\nname: #{name}\ndescription: Summarizes reports.\n---\nRead the reference and summarize.\n"

  defp mcp(servers),
    do:
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers" => servers
      })

  test "minimal manifest permits missing version and arbitrary optional metadata strings" do
    assert {:ok, %{skills: [], mcp_servers: %{}, diagnostics: []}} =
             PluginProtocol.load(%{"plugin.json" => manifest()})

    assert {:ok,
            %{manifest: %{"version" => "release-candidate next", "homepage" => "private docs"}}} =
             PluginProtocol.load(%{
               "plugin.json" =>
                 manifest(%{
                   "version" => "release-candidate next",
                   "homepage" => "private docs",
                   "license" => "Custom"
                 })
             })
  end

  test "standard package preserves resources, raw bytes, extension values and ignored unknown fields" do
    files = %{
      "plugin.json" =>
        manifest(%{
          "extensions" => %{"com.openai" => %{"apps" => ["app"]}, "com.unknown" => 7},
          "skills" => ["elsewhere"]
        }),
      "skills/summarize/SKILL.md" => skill(),
      "skills/summarize/references/report.md" => "report",
      "skills/summarize/scripts/run.py" => "print('ok')",
      "com.openai/hooks/hooks.json" => "{}",
      "mcp.json" =>
        mcp(%{
          "local" => %{
            "type" => "stdio",
            "command" => "python",
            "args" => ["${PLUGIN_ROOT}/server.py", "../opaque"],
            "env" => %{"UNKNOWN" => "${OTHER}"}
          },
          "remote" => %{"type" => "streamable-http", "url" => "https://example.com/mcp"}
        })
    }

    assert {:ok, package} = PluginProtocol.load(files)
    assert package.files == files

    assert [
             %{
               name: "summarize",
               path: "skills/summarize/SKILL.md",
               files: resources,
               content: content
             }
           ] = package.skills

    assert content == skill()
    assert resources["skills/summarize/scripts/run.py"] == "print('ok')"
    assert package.manifest["extensions"]["com.unknown"] == 7
    assert package.mcp_servers["local"]["args"] == ["${PLUGIN_ROOT}/server.py", "../opaque"]
    assert [%{code: :unknown_manifest_field, severity: :warning}] = package.diagnostics
  end

  test "manifest failures are fatal while non-object extensions only warn" do
    for extra <- [
          %{"name" => "Bad"},
          %{"name" => "bad--name"},
          %{"version" => 1},
          %{"author" => %{"company" => "Acme"}},
          %{"keywords" => [1]},
          %{"$schema" => "https://example.com/schema"}
        ] do
      assert {:error, [_ | _]} = PluginProtocol.load(%{"plugin.json" => manifest(extra)})
    end

    assert {:ok, %{diagnostics: [%{code: :invalid_extensions}]}} =
             PluginProtocol.load(%{"plugin.json" => manifest(%{"extensions" => []})})

    assert {:error, [%{code: :missing_manifest}]} = PluginProtocol.load(%{})

    assert {:error, [%{code: :invalid_manifest_json}]} =
             PluginProtocol.load(%{"plugin.json" => "{"})

    assert {:error, [%{code: :invalid_manifest}]} = PluginProtocol.load(%{"plugin.json" => "[]"})
  end

  test "invalid skill and individual server leave valid siblings available and discovery stays shallow" do
    files = %{
      "plugin.json" => manifest(),
      "skills/summarize/SKILL.md" => skill(),
      "skills/broken/SKILL.md" => skill("wrong"),
      "skills/nested/inner/SKILL.md" => skill("inner"),
      "mcp.json" =>
        mcp(%{
          "good" => %{"type" => "stdio", "command" => "node"},
          "bad" => %{"command" => "node"}
        })
    }

    assert {:ok,
            %{skills: [%{name: "summarize"}], mcp_servers: servers, diagnostics: diagnostics}} =
             PluginProtocol.load(files)

    assert Map.keys(servers) == ["good"]
    assert Enum.map(diagnostics, & &1.code) == [:invalid_skill, :invalid_mcp_server]

    for invalid <- [
          "not json",
          mcp(%{}) |> String.replace("1.0.0", "2.0.0"),
          JSON.encode!(%{
            "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
            "mcpServers" => %{},
            "extra" => true
          })
        ] do
      assert {:ok, %{skills: [%{name: "summarize"}], mcp_servers: empty, diagnostics: ds}} =
               PluginProtocol.load(Map.put(files, "mcp.json", invalid))

      assert empty == %{}
      assert Enum.any?(ds, &(&1.code == :invalid_mcp_config))
    end
  end

  test "invalid component location disables only that component" do
    assert {:ok,
            %{
              skills: [],
              mcp_servers: %{"ok" => _},
              diagnostics: [%{code: :invalid_skills_location}]
            }} =
             PluginProtocol.load(%{
               "plugin.json" => manifest(),
               "skills" => "not directory",
               "mcp.json" => mcp(%{"ok" => %{"type" => "stdio", "command" => "node"}})
             })

    assert {:ok, %{skills: [%{}], diagnostics: [%{code: :invalid_mcp_location}]}} =
             PluginProtocol.load(%{
               "plugin.json" => manifest(),
               "skills/summarize/SKILL.md" => skill(),
               "mcp.json/invalid" => "{}"
             })
  end

  test "MCP configuration rejects unsafe commands, cwd, reserved env, mixed variants and remote HTTP" do
    invalid = [
      %{"type" => "stdio", "command" => "node server.js"},
      %{"type" => "stdio", "command" => "../server"},
      %{"type" => "stdio", "command" => "${PLUGIN_ROOT}/server"},
      %{"type" => "stdio", "command" => "./../server"},
      %{"type" => "stdio", "command" => "node", "cwd" => "data"},
      %{"type" => "stdio", "command" => "node", "cwd" => "${PLUGIN_DATA}/../escape"},
      %{"type" => "stdio", "command" => "node", "env" => %{"PLUGIN_ROOT" => "override"}},
      %{"type" => "stdio", "command" => "node", "url" => "https://example.com"},
      %{"type" => "streamable-http", "url" => "http://example.com/mcp"},
      %{"type" => "streamable-http", "url" => "https://u:p@example.com/mcp"},
      %{"type" => "streamable-http", "url" => "https://example.com/mcp#x"},
      %{
        "type" => "streamable-http",
        "url" => "https://example.com",
        "headers" => %{"X-A" => "one", "x-a" => "two"}
      },
      %{
        "type" => "streamable-http",
        "url" => "https://example.com",
        "headers" => %{"X-A" => "x\r\ny"}
      }
    ]

    for config <- invalid do
      assert {:ok, %{mcp_servers: servers, diagnostics: [%{code: :invalid_mcp_server}]}} =
               PluginProtocol.load(%{
                 "plugin.json" => manifest(),
                 "mcp.json" => mcp(%{"test" => config})
               })

      assert servers == %{}
    end

    for url <- ["http://localhost/mcp", "http://127.2.3.4/mcp", "http://[::1]/mcp"] do
      assert {:ok, %{mcp_servers: %{"test" => _}, diagnostics: []}} =
               PluginProtocol.load(%{
                 "plugin.json" => manifest(),
                 "mcp.json" => mcp(%{"test" => %{"type" => "sse", "url" => url}})
               })
    end

    assert {:ok, %{diagnostics: [%{code: :unsupported_transport}]}} =
             PluginProtocol.load(
               %{
                 "plugin.json" => manifest(),
                 "mcp.json" =>
                   mcp(%{"test" => %{"type" => "sse", "url" => "https://example.com"}})
               },
               transports: ["stdio"]
             )
  end

  test "malformed remote authorities and ports invalidate only their own server" do
    for url <- [
          "https://example.com:bad/mcp",
          "https://[bad/mcp",
          "https://example.com:999999/mcp",
          "https://example.com:65536/mcp"
        ] do
      assert {:ok,
              %{
                skills: [%{name: "summarize"}],
                mcp_servers: servers,
                diagnostics: [%{code: :invalid_mcp_server}]
              }} =
               PluginProtocol.load(%{
                 "plugin.json" => manifest(),
                 "skills/summarize/SKILL.md" => skill(),
                 "mcp.json" =>
                   mcp(%{
                     "bad" => %{"type" => "streamable-http", "url" => url},
                     "good" => %{"type" => "streamable-http", "url" => "https://example.com/mcp"}
                   })
               })

      assert Map.keys(servers) == ["good"]
    end
  end

  test "skill optional field validation, YAML duplicate keys and directory-name agreement" do
    for document <- [
          String.replace(skill(), "summarize", "other"),
          String.replace(skill(), "description: Summarizes reports.", "description: ''"),
          String.replace(skill(), "description: Summarizes reports.", "description: [bad]"),
          String.replace(skill(), "name: summarize", "name: summarize\nname: summarize"),
          String.replace(skill(), "---\nRead", "metadata:\n  version: 1\n---\nRead")
        ] do
      assert {:ok, %{skills: [], diagnostics: [%{code: :invalid_skill}]}} =
               PluginProtocol.load(%{
                 "plugin.json" => manifest(),
                 "skills/summarize/SKILL.md" => document
               })
    end
  end

  test "empty metadata object remains a valid YAML mapping" do
    document = String.replace(skill(), "---\nRead", "metadata: {}\n---\nRead")

    assert {:ok, %{skills: [%{metadata: %{"metadata" => metadata}}], diagnostics: []}} =
             PluginProtocol.load(%{
               "plugin.json" => manifest(),
               "skills/summarize/SKILL.md" => document
             })

    assert metadata == %{}
  end
end
