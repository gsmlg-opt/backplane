defmodule Backplane.Memory.HookScriptsTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @hooks_dir Path.expand("../../priv/hooks", __DIR__)
  @memory_url "http://memory.test"
  @session "session-\"quoted\"\nline"
  @project "/work/project \"quoted\"\nline"
  @agent "agent-42"

  @cases [
    %{
      script: "session-start.sh",
      endpoint: "/api/memory/session/start",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => @agent
      },
      body: %{"session_id" => @session, "project" => @project, "agent_id" => @agent}
    },
    %{
      script: "session-end.sh",
      endpoint: "/api/memory/session/end",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => @agent
      },
      body: %{"session_id" => @session, "project" => @project, "agent_id" => @agent}
    },
    %{
      script: "user-prompt-submit.sh",
      endpoint: "/api/memory/observations",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => @agent,
        "prompt" => "Why \"now\"?\nExplain."
      },
      body: %{
        "session_id" => @session,
        "project" => @project,
        "agent_id" => @agent,
        "content" => "Why \"now\"?\nExplain.",
        "tool_name" => "user_prompt",
        "event_type" => "conversation.user_message",
        "payload" => %{"prompt" => "Why \"now\"?\nExplain."}
      }
    },
    %{
      script: "post-tool-use.sh",
      endpoint: "/api/memory/observations",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => @agent,
        "tool_name" => "Write",
        "tool_use_id" => "tool-123",
        "duration_ms" => 17,
        "tool_input" => %{
          "file_path" => "/tmp/a\"b",
          "metadata" => %{"lines" => ["one", "two\nthree"]}
        },
        "tool_response" => "done \"quoted\"\nnext"
      },
      body: %{
        "session_id" => @session,
        "project" => @project,
        "agent_id" => @agent,
        "content" => "done \"quoted\"\nnext",
        "tool_name" => "Write",
        "is_error" => false,
        "event_type" => "tool.call.completed",
        "idempotency_key" => "claude:tool:completed:#{@session}:tool-123",
        "payload" => %{
          "tool_input" => %{
            "file_path" => "/tmp/a\"b",
            "metadata" => %{"lines" => ["one", "two\nthree"]}
          },
          "tool_output" => "done \"quoted\"\nnext",
          "tool_use_id" => "tool-123",
          "duration_ms" => 17
        }
      }
    },
    %{
      script: "post-tool-use-failure.sh",
      endpoint: "/api/memory/observations",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => @agent,
        "tool_name" => "Bash",
        "tool_use_id" => "tool-fail",
        "duration_ms" => 23,
        "tool_input" => %{"command" => "false", "nested" => %{"retry" => false}},
        "error" => "failed \"badly\"\ntrace",
        "is_interrupt" => true
      },
      body: %{
        "session_id" => @session,
        "project" => @project,
        "agent_id" => @agent,
        "content" => "failed \"badly\"\ntrace",
        "tool_name" => "Bash",
        "is_error" => true,
        "event_type" => "tool.call.failed",
        "idempotency_key" => "claude:tool:failed:#{@session}:tool-fail",
        "payload" => %{
          "tool_input" => %{"command" => "false", "nested" => %{"retry" => false}},
          "tool_output" => %{
            "error" => "failed \"badly\"\ntrace",
            "is_interrupt" => true
          },
          "tool_use_id" => "tool-fail",
          "duration_ms" => 23
        }
      }
    },
    %{
      script: "pre-compact.sh",
      endpoint: "/api/memory/observations",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => @agent,
        "trigger" => "manual",
        "custom_instructions" => "Preserve \"decisions\"\nand failures"
      },
      body: %{
        "session_id" => @session,
        "project" => @project,
        "agent_id" => @agent,
        "content" => "Preserve \"decisions\"\nand failures",
        "tool_name" => "pre_compact",
        "event_type" => "legacy.observation",
        "payload" => %{
          "trigger" => "manual",
          "custom_instructions" => "Preserve \"decisions\"\nand failures"
        }
      }
    },
    %{
      script: "subagent-start.sh",
      endpoint: "/api/memory/observations",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => "child-1",
        "agent_type" => "Explore",
        "agent_transcript_path" => "/tmp/child.jsonl"
      },
      body: %{
        "session_id" => @session,
        "project" => @project,
        "agent_id" => "child-1",
        "content" => "Explore subagent started",
        "tool_name" => "subagent",
        "event_type" => "session.started",
        "idempotency_key" => "claude:subagent:started:#{@session}:child-1",
        "payload" => %{
          "agent_id" => "child-1",
          "agent_type" => "Explore",
          "agent_transcript_path" => "/tmp/child.jsonl"
        }
      }
    },
    %{
      script: "subagent-stop.sh",
      endpoint: "/api/memory/observations",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => "child-1",
        "agent_type" => "Explore",
        "agent_transcript_path" => "/tmp/child.jsonl",
        "last_assistant_message" => "Child says \"done\"\nnow"
      },
      body: %{
        "session_id" => @session,
        "project" => @project,
        "agent_id" => "child-1",
        "content" => "Child says \"done\"\nnow",
        "tool_name" => "subagent",
        "event_type" => "session.ended",
        "idempotency_key" => "claude:subagent:ended:#{@session}:child-1",
        "payload" => %{
          "agent_id" => "child-1",
          "agent_type" => "Explore",
          "agent_transcript_path" => "/tmp/child.jsonl",
          "last_assistant_message" => "Child says \"done\"\nnow"
        }
      }
    },
    %{
      script: "stop.sh",
      endpoint: "/api/memory/observations",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => @agent,
        "last_assistant_message" => "Finished \"cleanly\"\nbye"
      },
      body: %{
        "session_id" => @session,
        "project" => @project,
        "agent_id" => @agent,
        "content" => "Finished \"cleanly\"\nbye",
        "tool_name" => "stop",
        "event_type" => "agent.run.completed",
        "payload" => %{"last_assistant_message" => "Finished \"cleanly\"\nbye"}
      }
    },
    %{
      script: "post-commit.sh",
      endpoint: "/api/memory/observations",
      input: %{
        "session_id" => @session,
        "cwd" => @project,
        "agent_id" => @agent,
        "tool_name" => "Bash",
        "tool_use_id" => "tool-commit",
        "duration_ms" => 31,
        "tool_input" => %{"command" => "git commit -m \"fix: quote\""},
        "tool_response" => "[main abc123] fix: quote\n 1 file changed"
      },
      body: %{
        "session_id" => @session,
        "project" => @project,
        "agent_id" => @agent,
        "content" => "[main abc123] fix: quote\n 1 file changed",
        "tool_name" => "git_commit",
        "is_error" => false,
        "event_type" => "tool.call.completed",
        "idempotency_key" => "claude:git_commit:#{@session}:tool-commit",
        "payload" => %{
          "tool_input" => %{"command" => "git commit -m \"fix: quote\""},
          "tool_output" => "[main abc123] fix: quote\n 1 file changed",
          "tool_use_id" => "tool-commit",
          "duration_ms" => 31
        }
      }
    }
  ]

  for case_data <- @cases do
    @case_data case_data

    test "#{case_data.script} posts its explicit event mapping", %{tmp_dir: tmp_dir} do
      case_data = @case_data
      result = run_hook(case_data.script, case_data.input, tmp_dir)

      assert result.status == 0
      assert result.output == ""
      assert result.python_calls == 1

      assert result.args == [
               "-sf",
               "-m",
               "2.0",
               "-X",
               "POST",
               @memory_url <> case_data.endpoint,
               "-H",
               "Content-Type: application/json",
               "--data-binary",
               "@-"
             ]

      assert Jason.decode!(result.body) == case_data.body
    end
  end

  test "tool hook omits idempotency_key when tool_use_id is absent", %{tmp_dir: tmp_dir} do
    result =
      run_hook(
        "post-tool-use.sh",
        %{
          "session_id" => "session-no-tool-id",
          "cwd" => "/work",
          "tool_name" => "Read",
          "tool_input" => %{"file_path" => "/tmp/file"},
          "tool_response" => "contents"
        },
        tmp_dir
      )

    assert result.status == 0
    refute Map.has_key?(Jason.decode!(result.body), "idempotency_key")
  end

  test "post-commit ignores non-commit Bash commands", %{tmp_dir: tmp_dir} do
    for command <- [
          "git status",
          "echo git commit",
          "git commitment --help",
          ~s(printf "%s\\n" "nothing; git commit -m fake"),
          "printf '%s' 'nothing;\ngit commit -m fake'",
          "printf ';\n' git commit -m fake",
          "printf \";\n\" git commit -m fake",
          "cat <<'EOF'\ngit commit -m fake\nEOF",
          "cat <<'EOF';\ngit commit -m fake\nEOF"
        ] do
      result =
        run_hook(
          "post-commit.sh",
          %{
            "session_id" => "session-noncommit",
            "tool_name" => "Bash",
            "tool_use_id" => "tool-noncommit",
            "tool_input" => %{"command" => command},
            "tool_response" => "ok"
          },
          Path.join(tmp_dir, Integer.to_string(System.unique_integer([:positive])))
        )

      assert result.status == 0
      refute result.called_curl?
    end
  end

  for {behavior, command, expect_curl?} <- [
        {"ignores a command after a shell comment", "echo ok # comment; git commit -m fake",
         false},
        {"ignores a commit in a comment after a control operator",
         "echo ok; # git commit -m fake", false},
        {"recognizes a commit after a comment containing heredoc syntax",
         "echo ok # <<EOF\ngit commit -m after-comment", true},
        {"recognizes a commit after an unquoted hash inside a word",
         "echo foo#bar; git commit -m hash-in-word", true}
      ] do
    @comment_behavior behavior
    @comment_command command
    @comment_expect_curl expect_curl?

    test "post-commit #{@comment_behavior}", %{tmp_dir: tmp_dir} do
      result =
        run_hook(
          "post-commit.sh",
          %{
            "session_id" => "session-shell-comment",
            "tool_name" => "Bash",
            "tool_use_id" => "tool-shell-comment",
            "tool_input" => %{"command" => @comment_command},
            "tool_response" => "ok"
          },
          tmp_dir
        )

      assert result.status == 0
      assert result.called_curl? == @comment_expect_curl
    end
  end

  test "post-commit recognizes valid git invocations with shell and git options", %{
    tmp_dir: tmp_dir
  } do
    for command <- [
          "FOO=bar git commit -m env",
          "env FOO=bar git commit -m env-command",
          "git -c user.name=agent commit -m config",
          "cd /tmp && git -C /work -c user.name=agent commit -m chained",
          "git status;\ngit commit -m newline",
          "git status &&\ngit commit -m continued",
          "git status\n\ngit commit -m blank-line"
        ] do
      result =
        run_hook(
          "post-commit.sh",
          %{
            "session_id" => "session-valid-commit",
            "tool_name" => "Bash",
            "tool_use_id" => "tool-valid-commit",
            "tool_input" => %{"command" => command},
            "tool_response" => "committed"
          },
          Path.join(tmp_dir, Integer.to_string(System.unique_integer([:positive])))
        )

      assert result.status == 0
      assert result.called_curl?, "missed valid commit command: #{command}"
      assert Jason.decode!(result.body)["tool_name"] == "git_commit"
    end
  end

  for {quote_name, heredoc_body} <- [{"single quote", "'"}, {"double quote", "\""}] do
    @heredoc_body heredoc_body

    test "post-commit recognizes a commit after a heredoc body with an unmatched #{quote_name}",
         %{
           tmp_dir: tmp_dir
         } do
      command = "cat <<'EOF'\n#{@heredoc_body}\nEOF\ngit commit -m after-heredoc"

      result =
        run_hook(
          "post-commit.sh",
          %{
            "session_id" => "session-heredoc-commit",
            "tool_name" => "Bash",
            "tool_use_id" => "tool-heredoc-commit",
            "tool_input" => %{"command" => command},
            "tool_response" => "committed"
          },
          tmp_dir
        )

      assert result.status == 0
      assert result.called_curl?, "missed commit after #{unquote(quote_name)} heredoc body"
      assert Jason.decode!(result.body)["tool_name"] == "git_commit"
    end
  end

  test "post-commit recognizes a commit after multiple quoted heredocs", %{tmp_dir: tmp_dir} do
    command =
      "cat <<'FIRST' <<-\"SECOND\"\n'\nFIRST\n\t\"\n\tSECOND\ngit commit -m after-heredocs"

    result =
      run_hook(
        "post-commit.sh",
        %{
          "session_id" => "session-multiple-heredocs",
          "tool_name" => "Bash",
          "tool_use_id" => "tool-multiple-heredocs",
          "tool_input" => %{"command" => command},
          "tool_response" => "committed"
        },
        tmp_dir
      )

    assert result.status == 0
    assert result.called_curl?
    assert Jason.decode!(result.body)["tool_name"] == "git_commit"
  end

  for {behavior, command, expect_curl?} <- [
        {"keeps commits inside a hyphenated-delimiter heredoc opaque",
         "cat <<END-MARK\nEND\ngit commit -m fake\nEND-MARK", false},
        {"recognizes a commit after a hyphenated-delimiter heredoc",
         "cat <<END-MARK\nbody\nEND-MARK\ngit commit -m real", true},
        {"recognizes a commit after a tab-stripping hyphenated heredoc",
         "cat <<-END-MARK\n\tbody\n\tEND-MARK\ngit commit -m real-strip-tabs", true},
        {"recognizes a commit after a heredoc whose delimiter begins with a hyphen",
         "cat << -END\nbody\n-END\ngit commit -m real-leading-hyphen", true}
      ] do
    @hyphenated_heredoc_behavior behavior
    @hyphenated_heredoc_command command
    @hyphenated_heredoc_expect_curl expect_curl?

    test "post-commit #{@hyphenated_heredoc_behavior}", %{tmp_dir: tmp_dir} do
      result =
        run_hook(
          "post-commit.sh",
          %{
            "session_id" => "session-hyphenated-heredoc",
            "tool_name" => "Bash",
            "tool_use_id" => "tool-hyphenated-heredoc",
            "tool_input" => %{"command" => @hyphenated_heredoc_command},
            "tool_response" => "ok"
          },
          tmp_dir
        )

      assert result.status == 0
      assert result.called_curl? == @hyphenated_heredoc_expect_curl
    end
  end

  test "all scripts reject malformed or missing required input without calling curl", %{
    tmp_dir: tmp_dir
  } do
    for script <- hook_names(), input <- ["{malformed", %{}] do
      result =
        run_hook(
          script,
          input,
          Path.join(tmp_dir, Integer.to_string(System.unique_integer([:positive])))
        )

      assert result.status == 0
      refute result.called_curl?, "#{script} called curl for #{inspect(input)}"
    end
  end

  test "all scripts exit zero when curl fails", %{tmp_dir: tmp_dir} do
    for case_data <- @cases do
      result =
        run_hook(
          case_data.script,
          case_data.input,
          Path.join(tmp_dir, Integer.to_string(System.unique_integer([:positive]))),
          curl_exit: 7
        )

      assert result.status == 0
      assert result.called_curl?
    end
  end

  test "large structured tool input is consumed from stdin and never passed through argv", %{
    tmp_dir: tmp_dir
  } do
    large_value = String.duplicate("nested-data-\"quoted\"\n", 12_000)

    result =
      run_hook(
        "post-tool-use.sh",
        %{
          "session_id" => "large-session",
          "tool_name" => "Write",
          "tool_use_id" => "large-tool",
          "tool_input" => %{"nested" => %{"value" => large_value}},
          "tool_response" => "ok"
        },
        tmp_dir,
        max_python_arg_bytes: 16_384
      )

    assert result.status == 0
    assert result.python_calls == 1

    assert get_in(Jason.decode!(result.body), ["payload", "tool_input", "nested", "value"]) ==
             large_value
  end

  defp run_hook(script_name, input, tmp_dir, opts \\ []) do
    capture_dir = Path.join(tmp_dir, "capture")
    fake_bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(capture_dir)
    File.mkdir_p!(fake_bin)
    install_fake_curl!(fake_bin)
    install_python_wrapper!(fake_bin)

    input_path = Path.join(tmp_dir, "input.json")
    encoded = if is_binary(input), do: input, else: Jason.encode!(input)
    File.write!(input_path, encoded)

    env = [
      {"PATH", fake_bin <> ":" <> System.fetch_env!("PATH")},
      {"BACKPLANE_MEMORY_URL", @memory_url},
      {"AGENTMEMORY_SDK_CHILD", ""},
      {"HOOK_CAPTURE_DIR", capture_dir},
      {"HOOK_CURL_EXIT", Integer.to_string(Keyword.get(opts, :curl_exit, 0))},
      {"HOOK_MAX_ARG_BYTES", Integer.to_string(Keyword.get(opts, :max_python_arg_bytes, 0))}
    ]

    {output, status} =
      System.cmd(
        "bash",
        ["-c", ~s(exec "$1" < "$2"), "hook-test", hook_path(script_name), input_path],
        env: env,
        stderr_to_stdout: true
      )

    args_path = Path.join(capture_dir, "curl-args")
    body_path = Path.join(capture_dir, "curl-stdin")
    called_curl? = File.exists?(args_path)

    %{
      output: output,
      status: status,
      called_curl?: called_curl?,
      args: if(called_curl?, do: read_nul_args(args_path), else: []),
      body: if(File.exists?(body_path), do: File.read!(body_path), else: nil),
      python_calls: read_integer(Path.join(capture_dir, "python-count"))
    }
  end

  defp install_fake_curl!(fake_bin) do
    path = Path.join(fake_bin, "curl")

    File.write!(path, """
    #!/usr/bin/env bash
    printf '%s\\0' "$@" > "$HOOK_CAPTURE_DIR/curl-args"
    cat > "$HOOK_CAPTURE_DIR/curl-stdin"
    exit "${HOOK_CURL_EXIT:-0}"
    """)

    File.chmod!(path, 0o700)
  end

  defp install_python_wrapper!(fake_bin) do
    path = Path.join(fake_bin, "python3")
    real_python = System.find_executable("python3") || raise "python3 is required"

    File.write!(path, """
    #!/usr/bin/env bash
    count=0
    [ -f "$HOOK_CAPTURE_DIR/python-count" ] && count="$(cat "$HOOK_CAPTURE_DIR/python-count")"
    printf '%s' "$((count + 1))" > "$HOOK_CAPTURE_DIR/python-count"
    if [ "${HOOK_MAX_ARG_BYTES:-0}" -gt 0 ]; then
      for arg in "$@"; do
        [ "${#arg}" -le "$HOOK_MAX_ARG_BYTES" ] || exit 70
      done
    fi
    exec #{real_python} "$@"
    """)

    File.chmod!(path, 0o700)
  end

  defp hook_names, do: Enum.map(@cases, & &1.script)
  defp hook_path(name), do: Path.join(@hooks_dir, name)

  defp read_nul_args(path) do
    path
    |> File.read!()
    |> :binary.split(<<0>>, [:global, :trim])
  end

  defp read_integer(path) do
    if File.exists?(path), do: path |> File.read!() |> String.to_integer(), else: 0
  end
end
