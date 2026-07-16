defmodule Mix.Tasks.Memory.ConnectTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @events ~w(
    SessionStart
    SessionEnd
    UserPromptSubmit
    PostToolUse
    PostToolUseFailure
    PreCompact
    SubagentStart
    SubagentStop
    Stop
  )

  setup %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("HOME")
    home = Path.join(tmp_dir, "home")
    System.put_env("HOME", home)

    on_exit(fn ->
      restore_env("HOME", previous_home)
      Mix.Task.reenable("memory.connect")
    end)

    %{settings_path: Path.join([home, ".claude", "settings.json"])}
  end

  test "installs the current event-keyed hook schema with executable commands", %{
    settings_path: settings_path
  } do
    run_task()

    settings = read_settings(settings_path)
    hooks = settings["hooks"]

    assert Map.keys(hooks) |> Enum.sort() == Enum.sort(@events)
    assert handler_count(hooks) == 10

    assert [%{"hooks" => [session_start]}] = hooks["SessionStart"]
    assert Path.basename(session_start["command"]) == "session-start.sh"

    helper = Path.join(Path.dirname(session_start["command"]), "activation_session.py")
    assert File.regular?(helper)
    assert {:ok, %{access: access}} = File.stat(helper)
    assert access in [:read, :read_write]
    refute managed_command_present?(hooks, helper)

    assert [%{"hooks" => [session_end]}] = hooks["SessionEnd"]
    assert Path.basename(session_end["command"]) == "session-end.sh"
    assert session_end["timeout"] == 3

    assert [generic_group, commit_group] = hooks["PostToolUse"]
    refute Map.has_key?(generic_group, "matcher")
    assert [%{"command" => generic_command}] = generic_group["hooks"]
    assert Path.basename(generic_command) == "post-tool-use.sh"
    assert commit_group["matcher"] == "Bash"
    assert [%{"command" => commit_command}] = commit_group["hooks"]
    assert Path.basename(commit_command) == "post-commit.sh"

    assert [%{"hooks" => [failure]}] = hooks["PostToolUseFailure"]
    assert Path.basename(failure["command"]) == "post-tool-use-failure.sh"

    for {_event, groups} <- hooks,
        group <- groups,
        handler <- group["hooks"] do
      assert handler["type"] == "command"
      assert handler["args"] == []
      assert Path.type(handler["command"]) == :absolute
      assert File.regular?(handler["command"])
      assert executable?(handler["command"])
    end
  end

  test "a second run is structurally idempotent", %{settings_path: settings_path} do
    run_task()
    first = read_settings(settings_path)

    run_task()
    second = read_settings(settings_path)

    assert second == first
    assert handler_count(second["hooks"]) == 10
  end

  test "preserves unrelated settings, event groups, matchers, and sibling handlers", %{
    settings_path: settings_path
  } do
    sibling = %{"type" => "prompt", "prompt" => "keep sibling"}

    write_settings(settings_path, %{
      "permissions" => %{"allow" => ["Read"]},
      "hooks" => %{
        "CustomEvent" => [
          %{
            "matcher" => "custom",
            "hooks" => [%{"type" => "command", "command" => "/opt/custom"}]
          }
        ],
        "PostToolUse" => [
          %{
            "matcher" => "Bash",
            "hooks" => [
              %{
                "type" => "command",
                "command" => "/old/backplane_memory/priv/hooks/post-commit.sh"
              },
              sibling
            ]
          },
          %{
            "matcher" => "Write",
            "hooks" => [%{"type" => "command", "command" => "/opt/write-hook"}]
          }
        ],
        "SessionStart" => [
          %{
            "matcher" => "startup",
            "hooks" => [%{"type" => "command", "command" => "/opt/session-audit"}]
          }
        ]
      }
    })

    run_task()

    settings = read_settings(settings_path)
    assert settings["permissions"] == %{"allow" => ["Read"]}

    assert settings["hooks"]["CustomEvent"] == [
             %{
               "matcher" => "custom",
               "hooks" => [%{"type" => "command", "command" => "/opt/custom"}]
             }
           ]

    assert Enum.any?(settings["hooks"]["PostToolUse"], fn group ->
             group["matcher"] == "Bash" and sibling in group["hooks"]
           end)

    assert Enum.any?(settings["hooks"]["PostToolUse"], fn group ->
             group["matcher"] == "Write" and
               %{"type" => "command", "command" => "/opt/write-hook"} in group["hooks"]
           end)

    assert Enum.any?(settings["hooks"]["SessionStart"], fn group ->
             group["matcher"] == "startup"
           end)

    refute managed_command_present?(
             settings["hooks"],
             "/old/backplane_memory/priv/hooks/post-commit.sh"
           )
  end

  test "migrates the task's legacy flat list without dropping unrelated entries", %{
    settings_path: settings_path
  } do
    external = %{"type" => "command", "command" => "/opt/external-pre-tool"}
    sibling = %{"type" => "prompt", "prompt" => "keep me"}

    write_settings(settings_path, %{
      "hooks" => [
        %{"event" => "PreToolUse", "matcher" => "Bash", "hooks" => [external]},
        %{
          "event" => "PostToolUse",
          "hooks" => [
            %{
              "type" => "command",
              "command" => "/old/backplane_memory/priv/hooks/post-tool-use.sh"
            },
            sibling
          ]
        },
        %{
          "event" => "PostToolUse",
          "hooks" => [
            %{
              "type" => "command",
              "command" => "/old/backplane_memory/priv/hooks/post-tool-use-failure.sh"
            }
          ]
        }
      ]
    })

    run_task()

    hooks = read_settings(settings_path)["hooks"]
    assert is_map(hooks)
    assert %{"matcher" => "Bash", "hooks" => [^external]} = hd(hooks["PreToolUse"])
    assert Enum.any?(hooks["PostToolUse"], &(sibling in &1["hooks"]))

    refute managed_command_present?(
             hooks,
             "/old/backplane_memory/priv/hooks/post-tool-use.sh"
           )

    refute managed_command_present?(
             hooks,
             "/old/backplane_memory/priv/hooks/post-tool-use-failure.sh"
           )
  end

  test "removes a legacy event key when it contained only managed handlers", %{
    settings_path: settings_path
  } do
    write_settings(settings_path, %{
      "hooks" => [
        %{
          "event" => "PreToolUse",
          "hooks" => [
            %{
              "type" => "command",
              "command" => "/old/backplane_memory/priv/hooks/session-start.sh"
            }
          ]
        }
      ]
    })

    run_task()

    refute Map.has_key?(read_settings(settings_path)["hooks"], "PreToolUse")
  end

  test "malformed JSON fails without overwriting the settings file", %{
    settings_path: settings_path
  } do
    File.mkdir_p!(Path.dirname(settings_path))
    malformed = ~s({"permissions": [)
    File.write!(settings_path, malformed)

    assert_raise Jason.DecodeError, fn -> run_task() end
    assert File.read!(settings_path) == malformed
  end

  defp run_task do
    Mix.Task.reenable("memory.connect")
    Mix.Tasks.Memory.Connect.run([])
  end

  defp read_settings(path), do: path |> File.read!() |> Jason.decode!()

  defp write_settings(path, settings) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(settings, pretty: true))
  end

  defp handler_count(hooks) do
    Enum.sum(for {_event, groups} <- hooks, group <- groups, do: length(group["hooks"]))
  end

  defp managed_command_present?(hooks, command) do
    Enum.any?(hooks, fn {_event, groups} ->
      Enum.any?(groups, fn group ->
        Enum.any?(group["hooks"], &(&1["command"] == command))
      end)
    end)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
