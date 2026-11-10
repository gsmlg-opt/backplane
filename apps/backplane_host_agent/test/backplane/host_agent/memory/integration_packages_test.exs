defmodule Backplane.HostAgent.Memory.IntegrationPackagesTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.Hooks.ClaudeCode
  alias Backplane.MemoryToolContract

  @integrations Path.expand("../../../../../../integrations/memory", __DIR__)

  test "integrations/memory directory is located" do
    assert File.dir?(@integrations)
  end

  describe "shared" do
    test "INSTRUCTIONS.md equals the canonical resident instruction plus a newline" do
      path = Path.join(@integrations, "shared/INSTRUCTIONS.md")
      assert File.read!(path) == MemoryToolContract.instructions() <> "\n"
    end
  end

  describe "claude_code" do
    @claude Path.join(@integrations, "claude_code")
    @plugin Path.join(@claude, "backplane-memory")

    test "JSON files parse and manifests name the plugin" do
      for file <- ~w(.claude-plugin/marketplace.json) do
        assert File.read!(Path.join(@claude, file)) |> Jason.decode!()
      end

      for file <- ~w(.claude-plugin/plugin.json hooks/hooks.json .mcp.json) do
        assert File.read!(Path.join(@plugin, file)) |> Jason.decode!()
      end

      assert %{"name" => "backplane-memory", "version" => _, "description" => _} =
               Jason.decode!(File.read!(Path.join(@plugin, ".claude-plugin/plugin.json")))

      assert %{
               "name" => "backplane-local",
               "plugins" => [%{"name" => "backplane-memory", "source" => "./backplane-memory"}]
             } = Jason.decode!(File.read!(Path.join(@claude, ".claude-plugin/marketplace.json")))
    end

    test "hooks.json lists exactly the supported hooks via the hook client" do
      %{"hooks" => hooks} = Jason.decode!(File.read!(Path.join(@plugin, "hooks/hooks.json")))
      assert hooks |> Map.keys() |> Enum.sort() == Enum.sort(ClaudeCode.supported_hooks())

      for {hook, [%{"hooks" => [entry]} = group]} <- hooks do
        assert entry == %{
                 "type" => "command",
                 "command" => "__HOOK_CLIENT__ claude_code #{hook}"
               }

        if hook in ~w(PostToolUse PostToolUseFailure),
          do: assert(group["matcher"] == "*"),
          else: refute(Map.has_key?(group, "matcher"))
      end
    end

    test ".mcp.json points at the host agent claude-code MCP endpoint" do
      assert Jason.decode!(File.read!(Path.join(@plugin, ".mcp.json"))) == %{
               "mcpServers" => %{
                 "backplane-memory" => %{
                   "type" => "http",
                   "url" => "__HOST_AGENT_URL__/memory/claude-code/mcp"
                 }
               }
             }
    end

    test "SKILL.md body equals the shared instructions" do
      skill = File.read!(Path.join(@plugin, "skills/backplane-memory/SKILL.md"))

      assert [_, frontmatter, body] = String.split(skill, ~r/^---\n/m, parts: 3)
      assert frontmatter =~ "name: backplane-memory\n"
      assert frontmatter =~ "description: Use Backplane shared memory:"

      assert String.trim_leading(body, "\n") ==
               File.read!(Path.join(@integrations, "shared/INSTRUCTIONS.md"))
    end
  end
end
