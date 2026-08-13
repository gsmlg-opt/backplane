defmodule Backplane.Memory.HookScriptsTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @hooks_dir Path.expand("../../priv/hooks", __DIR__)
  @capture_url "http://127.0.0.1:4222/capture/v1/hooks/claude_code"
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
        "source" => "startup",
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

    test "#{case_data.script} forwards its raw payload to local capture", %{tmp_dir: tmp_dir} do
      case_data = @case_data
      result = run_hook(case_data.script, case_data.input, tmp_dir)

      assert result.status == 0
      assert result.output == ""
      assert result.python_calls == 1

      timeout =
        if case_data.script in ["session-start.sh", "pre-compact.sh"], do: "1.5", else: "2.0"

      assert result.args == [
               "-sf",
               "-m",
               timeout,
               "-X",
               "POST",
               @capture_url <> "/" <> hook_class(case_data.script),
               "-H",
               "Content-Type: application/json",
               "--data-binary",
               "@-"
             ]

      assert Jason.decode!(result.body) == case_data.input
    end
  end

  test "session-start emits official additionalContext JSON only for non-empty context", %{
    tmp_dir: tmp_dir
  } do
    response =
      Jason.encode!(%{
        "ok" => true,
        "lifecycle_context" => %{
          "context" => "trusted memory context",
          "cached" => false,
          "stale" => false
        }
      })

    result =
      run_hook(
        "session-start.sh",
        %{"session_id" => "context-session", "source" => "startup", "cwd" => "/work"},
        tmp_dir,
        seed: false,
        curl_response: response
      )

    assert Jason.decode!(result.output) == %{
             "hookSpecificOutput" => %{
               "hookEventName" => "SessionStart",
               "additionalContext" => "trusted memory context"
             }
           }
  end

  test "pre-compact retrieves context without fabricating hook output", %{tmp_dir: tmp_dir} do
    runtime_dir = Path.join(tmp_dir, "runtime")
    memory_id = establish_activation!("precompact-context", "startup", runtime_dir)

    result =
      run_hook(
        "pre-compact.sh",
        %{"session_id" => "precompact-context", "cwd" => "/work"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false,
        curl_response: Jason.encode!(%{"lifecycle_context" => %{"context" => "must not print"}})
      )

    assert result.output == ""
    assert Jason.decode!(result.body)["session_id"] == memory_id
    assert result.args |> Enum.chunk_every(2, 1) |> Enum.any?(&(&1 == ["-m", "1.5"]))
  end

  for case_data <- @cases do
    @resolved_case case_data

    test "#{case_data.script} posts the resolved activation ID", %{tmp_dir: tmp_dir} do
      case_data = @resolved_case
      claude_id = "claude-translation-#{case_data.script}"
      runtime_dir = Path.join(tmp_dir, "runtime")
      memory_id = establish_activation!(claude_id, "resume", runtime_dir)

      input =
        case_data.input
        |> Map.put("session_id", claude_id)
        |> then(fn input ->
          if case_data.script == "session-start.sh",
            do: Map.put(input, "source", "compact"),
            else: input
        end)

      result =
        run_hook(case_data.script, input, tmp_dir,
          runtime_dir: runtime_dir,
          seed: false
        )

      assert result.status == 0
      assert result.called_curl?
      body = Jason.decode!(result.body)
      assert body["session_id"] == memory_id
      assert body == Map.put(input, "session_id", memory_id)
    end
  end

  for case_data <- Enum.reject(@cases, &(&1.script == "session-start.sh")) do
    @missing_state_case case_data

    test "#{case_data.script} makes no request without activation state", %{tmp_dir: tmp_dir} do
      case_data = @missing_state_case

      result =
        run_hook(
          case_data.script,
          Map.put(case_data.input, "session_id", "claude-missing-#{case_data.script}"),
          tmp_dir,
          seed: false
        )

      assert result.status == 0
      refute result.called_curl?
    end
  end

  for {label, source} <- [{"missing", nil}, {"unsupported", "reconnect"}] do
    @source_label label
    @activation_source source

    test "session-start rejects #{@source_label} activation source", %{tmp_dir: tmp_dir} do
      input = %{"session_id" => "claude-invalid-source", "cwd" => "/work"}

      input =
        if @activation_source,
          do: Map.put(input, "source", @activation_source),
          else: input

      result = run_hook("session-start.sh", input, tmp_dir, seed: false)

      assert result.status == 0
      refute result.called_curl?
    end
  end

  test "session-start compact makes no request without activation state", %{tmp_dir: tmp_dir} do
    result =
      run_hook(
        "session-start.sh",
        %{"session_id" => "claude-compact-without-state", "source" => "compact"},
        tmp_dir,
        seed: false
      )

    assert result.status == 0
    refute result.called_curl?
  end

  test "startup, end, and resume use distinct activation sessions", %{tmp_dir: tmp_dir} do
    claude_id = "claude-lifecycle"
    runtime_dir = Path.join(tmp_dir, "runtime")

    startup =
      run_hook(
        "session-start.sh",
        %{"session_id" => claude_id, "source" => "startup", "cwd" => "/work"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    startup_id = body_session_id(startup)
    assert startup_id == claude_id

    startup_observation =
      run_hook(
        "user-prompt-submit.sh",
        %{"session_id" => claude_id, "prompt" => "first activation"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    assert body_session_id(startup_observation) == startup_id

    startup_end =
      run_hook(
        "session-end.sh",
        %{"session_id" => claude_id, "cwd" => "/work"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    assert body_session_id(startup_end) == startup_id
    assert resolve_activation(claude_id, runtime_dir) == nil

    resume =
      run_hook(
        "session-start.sh",
        %{"session_id" => claude_id, "source" => "resume", "cwd" => "/work"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    resume_id = body_session_id(resume)
    assert resume_id =~ activation_id_pattern()
    refute resume_id == startup_id

    resume_observation =
      run_hook(
        "user-prompt-submit.sh",
        %{"session_id" => claude_id, "prompt" => "second activation"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    assert body_session_id(resume_observation) == resume_id

    resume_end =
      run_hook(
        "session-end.sh",
        %{"session_id" => claude_id, "cwd" => "/work"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    assert body_session_id(resume_end) == resume_id
    assert resolve_activation(claude_id, runtime_dir) == nil
  end

  test "compact reuses the active Memory session", %{tmp_dir: tmp_dir} do
    claude_id = "claude-compact-lifecycle"
    runtime_dir = Path.join(tmp_dir, "runtime")

    resume =
      run_hook(
        "session-start.sh",
        %{"session_id" => claude_id, "source" => "resume"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    compact =
      run_hook(
        "session-start.sh",
        %{"session_id" => claude_id, "source" => "compact"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    resume_id = body_session_id(resume)
    assert resume_id =~ activation_id_pattern()
    assert body_session_id(compact) == resume_id
    assert resolve_activation(claude_id, runtime_dir) == resume_id
  end

  test "clear identity maps the new Claude session", %{tmp_dir: tmp_dir} do
    old_claude_id = "claude-before-clear-hook"
    new_claude_id = "claude-after-clear-hook"
    runtime_dir = Path.join(tmp_dir, "runtime")

    old_resume =
      run_hook(
        "session-start.sh",
        %{"session_id" => old_claude_id, "source" => "resume"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    clear =
      run_hook(
        "session-start.sh",
        %{"session_id" => new_claude_id, "source" => "clear"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    old_memory_id = body_session_id(old_resume)
    assert old_memory_id =~ activation_id_pattern()
    assert body_session_id(clear) == new_claude_id
    assert resolve_activation(new_claude_id, runtime_dir) == new_claude_id
    assert resolve_activation(old_claude_id, runtime_dir) == old_memory_id
  end

  test "two Claude sessions remain isolated in one runtime directory", %{tmp_dir: tmp_dir} do
    runtime_dir = Path.join(tmp_dir, "runtime")

    first_start =
      run_hook(
        "session-start.sh",
        %{"session_id" => "claude-isolated-a", "source" => "resume"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    second_start =
      run_hook(
        "session-start.sh",
        %{"session_id" => "claude-isolated-b", "source" => "resume"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    first_id = body_session_id(first_start)
    second_id = body_session_id(second_start)
    assert first_id =~ activation_id_pattern()
    assert second_id =~ activation_id_pattern()
    refute first_id == second_id

    first_observation =
      run_hook(
        "user-prompt-submit.sh",
        %{"session_id" => "claude-isolated-a", "prompt" => "first"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    second_observation =
      run_hook(
        "user-prompt-submit.sh",
        %{"session_id" => "claude-isolated-b", "prompt" => "second"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    assert body_session_id(first_observation) == first_id
    assert body_session_id(second_observation) == second_id
  end

  test "failed SessionEnd curl still removes the captured mapping", %{tmp_dir: tmp_dir} do
    claude_id = "claude-failed-end"
    runtime_dir = Path.join(tmp_dir, "runtime")
    memory_id = establish_activation!(claude_id, "resume", runtime_dir)

    result =
      run_hook(
        "session-end.sh",
        %{"session_id" => claude_id},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false,
        curl_exit: 7
      )

    assert result.status == 0
    assert result.called_curl?
    assert resolve_activation(claude_id, runtime_dir) == nil
    assert body_session_id(result) == memory_id
  end

  test "blocked SessionEnd cleanup preserves a newer resume mapping", %{tmp_dir: tmp_dir} do
    claude_id = "claude-end-resume-race"
    runtime_dir = Path.join(tmp_dir, "runtime")
    started = Path.join(tmp_dir, "curl-started")
    release = Path.join(tmp_dir, "curl-release")
    old_memory_id = establish_activation!(claude_id, "resume", runtime_dir)

    ending =
      Task.async(fn ->
        run_hook(
          "session-end.sh",
          %{"session_id" => claude_id},
          tmp_dir,
          runtime_dir: runtime_dir,
          seed: false,
          curl_started: started,
          curl_release: release
        )
      end)

    wait_for_file!(started)

    resume =
      run_hook(
        "session-start.sh",
        %{"session_id" => claude_id, "source" => "resume"},
        tmp_dir,
        runtime_dir: runtime_dir,
        seed: false
      )

    File.touch!(release)
    ended = Task.await(ending, 5_000)
    new_memory_id = body_session_id(resume)

    assert body_session_id(ended) == old_memory_id
    assert new_memory_id =~ activation_id_pattern()
    refute new_memory_id == old_memory_id
    assert resolve_activation(claude_id, runtime_dir) == new_memory_id
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
      assert Jason.decode!(result.body)["tool_name"] == "Bash"
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
      assert Jason.decode!(result.body)["tool_name"] == "Bash"
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
    assert Jason.decode!(result.body)["tool_name"] == "Bash"
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

  test "hook scripts contain no direct central memory API calls" do
    for script <- hook_names() do
      source = File.read!(hook_path(script))
      refute source =~ ":4220", "#{script} still references the central memory port"
      refute source =~ "/api/memory", "#{script} still references the central memory API"
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

    assert get_in(Jason.decode!(result.body), ["tool_input", "nested", "value"]) ==
             large_value
  end

  test "hook scripts honor the configured host-agent URL", %{tmp_dir: tmp_dir} do
    capture_base = "http://127.0.0.1:4999"

    result =
      run_hook(
        "user-prompt-submit.sh",
        %{"session_id" => "configured-port", "prompt" => "capture locally"},
        tmp_dir,
        capture_base: capture_base
      )

    assert Enum.at(result.args, 5) ==
             capture_base <> "/capture/v1/hooks/claude_code/UserPromptSubmit"
  end

  defp run_hook(script_name, input, tmp_dir, opts \\ []) do
    invocation = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    capture_dir = Path.join(tmp_dir, "capture-#{invocation}")
    fake_bin = Path.join(tmp_dir, "bin-#{invocation}")
    runtime_dir = Keyword.get(opts, :runtime_dir, Path.join(tmp_dir, "runtime"))
    tmp_root = Path.join(tmp_dir, "tmp")
    File.mkdir_p!(capture_dir)
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(runtime_dir)
    File.mkdir_p!(tmp_root)
    install_fake_curl!(fake_bin)
    install_python_wrapper!(fake_bin)

    if Keyword.get(opts, :seed, true) and is_map(input) and is_binary(input["session_id"]) do
      establish_activation!(input["session_id"], "startup", runtime_dir)
    end

    input_path = Path.join(tmp_dir, "input-#{invocation}.json")
    encoded = if is_binary(input), do: input, else: Jason.encode!(input)
    File.write!(input_path, encoded)

    env = [
      {"PATH", fake_bin <> ":" <> System.fetch_env!("PATH")},
      {"BACKPLANE_MEMORY_URL", @memory_url},
      {"BACKPLANE_HOST_AGENT_URL", Keyword.get(opts, :capture_base)},
      {"AGENTMEMORY_SDK_CHILD", ""},
      {"HOOK_CAPTURE_DIR", capture_dir},
      {"XDG_RUNTIME_DIR", runtime_dir},
      {"TMPDIR", tmp_root},
      {"HOOK_CURL_EXIT", Integer.to_string(Keyword.get(opts, :curl_exit, 0))},
      {"HOOK_MAX_ARG_BYTES", Integer.to_string(Keyword.get(opts, :max_python_arg_bytes, 0))},
      {"HOOK_CURL_STARTED", Keyword.get(opts, :curl_started, "")},
      {"HOOK_CURL_RELEASE", Keyword.get(opts, :curl_release, "")},
      {"HOOK_CURL_RESPONSE", Keyword.get(opts, :curl_response, "")}
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
    [ -n "${HOOK_CURL_STARTED:-}" ] && : > "$HOOK_CURL_STARTED"
    while [ -n "${HOOK_CURL_RELEASE:-}" ] && [ ! -e "$HOOK_CURL_RELEASE" ]; do
      sleep 0.01
    done
    printf '%s' "${HOOK_CURL_RESPONSE:-}"
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

  defp hook_class("session-start.sh"), do: "SessionStart"
  defp hook_class("user-prompt-submit.sh"), do: "UserPromptSubmit"
  defp hook_class("post-tool-use.sh"), do: "PostToolUse"
  defp hook_class("post-tool-use-failure.sh"), do: "PostToolUseFailure"
  defp hook_class("pre-compact.sh"), do: "PreCompact"
  defp hook_class("subagent-start.sh"), do: "SubagentStart"
  defp hook_class("subagent-stop.sh"), do: "SubagentStop"
  defp hook_class("stop.sh"), do: "Stop"
  defp hook_class("session-end.sh"), do: "SessionEnd"
  defp hook_class("post-commit.sh"), do: "PostCommit"

  defp body_session_id(result), do: result.body |> Jason.decode!() |> Map.fetch!("session_id")

  defp activation_id_pattern do
    ~r/^claude-run-[0-9a-f]{12}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  end

  defp establish_activation!(claude_id, source, runtime_dir) do
    result = activation_call(claude_id, runtime_dir, "establish", source)
    assert is_binary(result)
    result
  end

  defp resolve_activation(claude_id, runtime_dir) do
    activation_call(claude_id, runtime_dir, "resolve")
  end

  defp activation_call(claude_id, runtime_dir, operation, source \\ "") do
    File.mkdir_p!(runtime_dir)
    python = System.find_executable("python3") || raise "python3 is required"

    script = """
    import json
    import sys
    from activation_session import establish, resolve

    if sys.argv[1] == "establish":
        result = establish(sys.argv[2], sys.argv[3])
    else:
        result = resolve(sys.argv[2])

    print(json.dumps(result))
    """

    {output, status} =
      System.cmd(python, ["-c", script, operation, claude_id, source],
        env: [
          {"PYTHONPATH", @hooks_dir},
          {"XDG_RUNTIME_DIR", runtime_dir}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    Jason.decode!(output)
  end

  defp wait_for_file!(path, attempts \\ 500) do
    cond do
      File.exists?(path) ->
        :ok

      attempts == 0 ->
        flunk("timed out waiting for fake curl")

      true ->
        Process.sleep(10)
        wait_for_file!(path, attempts - 1)
    end
  end

  defp read_nul_args(path) do
    path
    |> File.read!()
    |> :binary.split(<<0>>, [:global, :trim])
  end

  defp read_integer(path) do
    if File.exists?(path), do: path |> File.read!() |> String.to_integer(), else: 0
  end
end

defmodule Backplane.Memory.ActivationSessionTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defp run_activation_session(tmp_dir, script, opts \\ []) do
    hooks_path = Path.expand("../../priv/hooks", __DIR__)
    runtime_dir = Keyword.get(opts, :runtime_dir, Path.join(tmp_dir, "runtime"))

    if Keyword.get(opts, :create_runtime_dir?, true) do
      File.mkdir_p!(runtime_dir)
    end

    env =
      if Keyword.get(opts, :xdg_runtime?, true) do
        [
          {"PYTHONPATH", hooks_path},
          {"XDG_RUNTIME_DIR", runtime_dir}
        ]
      else
        [
          {"PYTHONPATH", hooks_path},
          {"XDG_RUNTIME_DIR", nil},
          {"TMPDIR", runtime_dir}
        ]
      end

    {output, status} = System.cmd("python3", ["-c", script], env: env, stderr_to_stdout: true)
    assert status == 0, output
    Jason.decode!(output)
  end

  defp descriptor_fault_script(mode) do
    """
    import json
    import os
    import stat
    import activation_session

    mode = #{inspect(mode)}
    real_fchmod = activation_session.os.fchmod
    real_flock = activation_session.fcntl.flock
    regular_fchmod_calls = 0

    def fd_count():
        root = next(path for path in ("/proc/self/fd", "/dev/fd") if os.path.isdir(path))
        return len(os.listdir(root))

    def injected_fchmod(fd, permissions):
        global regular_fchmod_calls
        if stat.S_ISDIR(os.fstat(fd).st_mode):
            return real_fchmod(fd, permissions)

        regular_fchmod_calls += 1
        if mode == "lock_fchmod" or (
            mode == "temp_fchmod" and regular_fchmod_calls % 2 == 0
        ):
            raise OSError("injected fchmod failure")
        return real_fchmod(fd, permissions)

    def injected_flock(fd, operation):
        if mode == "unlock" and operation == activation_session.fcntl.LOCK_UN:
            raise OSError("injected unlock failure")
        return real_flock(fd, operation)

    activation_session.os.fchmod = injected_fchmod
    activation_session.fcntl.flock = injected_flock
    before = fd_count()
    results = [
        activation_session.establish(f"claude-descriptor-{index}", "startup")
        for index in range(16)
    ]
    after = fd_count()
    print(json.dumps({"results": results, "fd_delta": after - before}))
    """
  end

  test "activation identity follows startup, resume, and compact lifecycle", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import establish, resolve

      claude_id = "claude-session-1"
      startup_id = establish(claude_id, "startup")
      startup_resolved = resolve(claude_id)
      resume_id = establish(claude_id, "resume")
      resume_resolved = resolve(claude_id)
      compact_id = establish(claude_id, "compact")

      print(json.dumps({
          "startup_id": startup_id,
          "startup_resolved": startup_resolved,
          "resume_id": resume_id,
          "resume_resolved": resume_resolved,
          "compact_id": compact_id,
      }))
      """)

    assert result["startup_id"] == "claude-session-1"
    assert result["startup_resolved"] == "claude-session-1"

    assert result["resume_id"] =~
             ~r/^claude-run-[0-9a-f]{12}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    refute result["resume_id"] == "claude-session-1"
    assert result["resume_resolved"] == result["resume_id"]
    assert result["compact_id"] == result["resume_id"]
  end

  test "clear establishes an identity mapping", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import establish, resolve

      claude_id = "claude-clear-session"
      resumed_id = establish(claude_id, "resume")
      clear_id = establish(claude_id, "clear")

      print(json.dumps({
          "resumed_id": resumed_id,
          "clear_id": clear_id,
          "resolved_id": resolve(claude_id),
      }))
      """)

    refute result["resumed_id"] == "claude-clear-session"
    assert result["clear_id"] == "claude-clear-session"
    assert result["resolved_id"] == "claude-clear-session"
  end

  test "compact and resolve return no activation without state", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import establish, prepare_end, resolve

      claude_id = "claude-missing-session"

      print(json.dumps({
          "compact_id": establish(claude_id, "compact"),
          "resolved_id": resolve(claude_id),
          "end_token": prepare_end(claude_id),
      }))
      """)

    assert result == %{
             "compact_id" => nil,
             "resolved_id" => nil,
             "end_token" => nil
           }
  end

  test "cleanup uses compare-and-swap semantics", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import cleanup, establish, prepare_end, resolve

      claude_id = "claude-cas-session"
      old_id = establish(claude_id, "startup")
      old_digest, prepared_id = prepare_end(claude_id)
      newer_id = establish(claude_id, "resume")
      cleaned = cleanup(old_digest, prepared_id)

      print(json.dumps({
          "old_id": old_id,
          "prepared_id": prepared_id,
          "newer_id": newer_id,
          "cleaned": cleaned,
          "resolved_id": resolve(claude_id),
      }))
      """)

    assert result["old_id"] == "claude-cas-session"
    assert result["prepared_id"] == result["old_id"]
    refute result["newer_id"] == result["old_id"]
    refute result["cleaned"]
    assert result["resolved_id"] == result["newer_id"]
  end

  test "cleanup removes the current mapping using the prepared digest", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import cleanup, establish, prepare_end, resolve

      claude_id = "claude-current-cleanup"
      memory_id = establish(claude_id, "startup")
      digest, prepared_id = prepare_end(claude_id)
      record_path = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks" / f"{digest}.json"
      cleaned = cleanup(digest, prepared_id)

      print(json.dumps({
          "memory_id": memory_id,
          "prepared_id": prepared_id,
          "digest": digest,
          "expected_digest": hashlib.sha256(claude_id.encode("utf-8")).hexdigest(),
          "cleaned": cleaned,
          "record_exists": record_path.exists(),
          "resolved_id": resolve(claude_id),
      }))
      """)

    assert result["prepared_id"] == result["memory_id"]
    assert result["digest"] == result["expected_digest"]
    assert result["cleaned"]
    refute result["record_exists"]
    assert result["resolved_id"] == nil
  end

  test "each resume establishes a fresh activation", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import establish, resolve

      claude_id = "claude-repeated-resume"
      first_id = establish(claude_id, "resume")
      second_id = establish(claude_id, "resume")

      print(json.dumps({
          "first_id": first_id,
          "second_id": second_id,
          "resolved_id": resolve(claude_id),
      }))
      """)

    refute result["first_id"] == result["second_id"]
    assert result["resolved_id"] == result["second_id"]
  end

  test "Claude session mappings remain independent", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import establish, resolve

      first_claude_id = "claude-independent-one"
      second_claude_id = "claude-independent-two"
      first_memory_id = establish(first_claude_id, "startup")
      second_memory_id = establish(second_claude_id, "resume")

      print(json.dumps({
          "first_memory_id": first_memory_id,
          "second_memory_id": second_memory_id,
          "first_resolved": resolve(first_claude_id),
          "second_resolved": resolve(second_claude_id),
      }))
      """)

    assert result["first_memory_id"] == "claude-independent-one"
    refute result["second_memory_id"] == "claude-independent-two"
    assert result["first_resolved"] == result["first_memory_id"]
    assert result["second_resolved"] == result["second_memory_id"]
    refute result["first_resolved"] == result["second_resolved"]
  end

  test "activation state is private, hashed, and contains only mapping data", %{tmp_dir: tmp_dir} do
    claude_id = "claude-private-session"
    prompt = "sensitive prompt must not persist"

    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import establish

      claude_id = #{inspect(claude_id)}
      prompt = #{inspect(prompt)}
      establish(claude_id, "startup")

      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      state_root = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks"
      record_path = state_root / f"{digest}.json"
      root_mode = state_root.stat().st_mode & 0o777
      startup_record_mode = record_path.stat().st_mode & 0o777

      establish(claude_id, "resume")
      resumed_record = record_path.read_text(encoding="utf-8")

      print(json.dumps({
          "root_mode": root_mode,
          "startup_record_mode": startup_record_mode,
          "basename": record_path.name,
          "record": json.loads(resumed_record),
          "raw_record": resumed_record,
          "prompt": prompt,
      }))
      """)

    expected_digest =
      :sha256
      |> :crypto.hash(claude_id)
      |> Base.encode16(case: :lower)

    assert result["root_mode"] == 0o700
    assert result["startup_record_mode"] == 0o600
    assert result["basename"] == expected_digest <> ".json"

    assert result["record"]
           |> Map.keys()
           |> Enum.sort() == ["claude_session_sha256", "memory_session_id", "version"]

    refute result["raw_record"] =~ claude_id
    refute result["raw_record"] =~ prompt
  end

  test "lock and replacement record files remain private", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import establish

      claude_id = "claude-private-files"
      establish(claude_id, "startup")
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      state_root = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks"
      lock_path = state_root / f"{digest}.lock"
      record_path = state_root / f"{digest}.json"
      initial_record_mode = record_path.stat().st_mode & 0o777

      establish(claude_id, "resume")

      print(json.dumps({
          "lock_mode": lock_path.stat().st_mode & 0o777,
          "initial_record_mode": initial_record_mode,
          "replacement_record_mode": record_path.stat().st_mode & 0o777,
      }))
      """)

    assert result == %{
             "lock_mode" => 0o600,
             "initial_record_mode" => 0o600,
             "replacement_record_mode" => 0o600
           }
  end

  test "malformed activation state is ignored", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import establish, resolve

      claude_id = "claude-malformed-state"
      establish(claude_id, "startup")
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      record_path = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks" / f"{digest}.json"
      record_path.write_text("{malformed", encoding="utf-8")

      print(json.dumps({"resolved_id": resolve(claude_id)}))
      """)

    assert result["resolved_id"] == nil
  end

  test "activation state with the wrong digest is ignored", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import establish, resolve

      claude_id = "claude-wrong-digest"
      establish(claude_id, "startup")
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      record_path = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks" / f"{digest}.json"
      record_path.write_text(json.dumps({
          "version": 1,
          "claude_session_sha256": "0" * 64,
          "memory_session_id": "forged-memory-session",
      }), encoding="utf-8")

      print(json.dumps({"resolved_id": resolve(claude_id)}))
      """)

    assert result["resolved_id"] == nil
  end

  test "activation state with a non-integer or unknown version is ignored", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import establish, resolve

      claude_id = "claude-wrong-version"
      establish(claude_id, "startup")
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      record_path = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks" / f"{digest}.json"
      resolved_ids = {}

      for label, version in (("unknown", 2), ("boolean", True), ("float", 1.0)):
          record_path.write_text(json.dumps({
              "version": version,
              "claude_session_sha256": digest,
              "memory_session_id": "forged-memory-session",
          }), encoding="utf-8")
          resolved_ids[label] = resolve(claude_id)

      print(json.dumps(resolved_ids))
      """)

    assert result == %{
             "unknown" => nil,
             "boolean" => nil,
             "float" => nil
           }
  end

  test "a FIFO activation record is rejected without blocking", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      import subprocess
      import sys

      claude_id = "claude-fifo-state"
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      state_root = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks"
      state_root.mkdir(mode=0o700)
      os.mkfifo(state_root / f"{digest}.json", 0o600)
      child_script = (
          'import json, os; '
          'from activation_session import resolve; '
          'fd_root = next(path for path in ("/proc/self/fd", "/dev/fd") if os.path.isdir(path)); '
          'before = len(os.listdir(fd_root)); '
          'resolved_ids = [resolve("claude-fifo-state") for _ in range(32)]; '
          'after = len(os.listdir(fd_root)); '
          'print(json.dumps({"resolved_ids": resolved_ids, "fd_delta": after - before}))'
      )

      try:
          child = subprocess.run(
              [sys.executable, "-c", child_script],
              capture_output=True,
              check=False,
              text=True,
              timeout=1.0,
          )
          print(json.dumps({
              "timed_out": False,
              "status": child.returncode,
              "stdout": child.stdout,
          }))
      except subprocess.TimeoutExpired:
          print(json.dumps({"timed_out": True}))
      """)

    refute result["timed_out"]
    assert result["status"] == 0

    child_result = Jason.decode!(result["stdout"])
    assert Enum.all?(child_result["resolved_ids"], &is_nil/1)
    assert child_result["fd_delta"] == 0
  end

  test "activation state rejects a root owned by another user", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      import os
      from types import SimpleNamespace
      import activation_session

      real_fstat = activation_session.os.fstat

      def foreign_root(fd):
          details = real_fstat(fd)
          return SimpleNamespace(st_mode=details.st_mode, st_uid=os.getuid() + 1)

      activation_session.os.fstat = foreign_root
      memory_id = activation_session.establish("claude-foreign-root", "startup")
      print(json.dumps({"memory_id": memory_id}))
      """)

    assert result["memory_id"] == nil
  end

  test "state operations remain anchored when the root path is replaced", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      import stat
      import activation_session

      claude_id = "claude-root-swap"
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      runtime_root = Path(os.environ["XDG_RUNTIME_DIR"])
      state_root = runtime_root / "backplane-memory-hooks"
      anchored_root = runtime_root / "anchored-root"
      redirected_root = runtime_root / "redirected-root"
      redirected_root.mkdir(mode=0o700)
      real_fchmod = activation_session.os.fchmod
      swapped = False

      def swap_on_lock(fd, mode):
          global swapped
          real_fchmod(fd, mode)
          if not swapped and stat.S_ISREG(os.fstat(fd).st_mode):
              state_root.rename(anchored_root)
              state_root.symlink_to(redirected_root, target_is_directory=True)
              swapped = True

      activation_session.os.fchmod = swap_on_lock
      memory_id = activation_session.establish(claude_id, "startup")

      print(json.dumps({
          "memory_id": memory_id,
          "anchored_record": (anchored_root / f"{digest}.json").is_file(),
          "redirected_record": (redirected_root / f"{digest}.json").exists(),
      }))
      """)

    assert result == %{
             "memory_id" => "claude-root-swap",
             "anchored_record" => true,
             "redirected_record" => false
           }
  end

  test "lock descriptor closes when permission setup fails", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, descriptor_fault_script("lock_fchmod"))

    assert result["fd_delta"] == 0
    assert Enum.all?(result["results"], &is_nil/1)
  end

  test "temporary descriptor closes when permission setup fails", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, descriptor_fault_script("temp_fchmod"))

    assert result["fd_delta"] == 0
    assert Enum.all?(result["results"], &is_nil/1)
  end

  test "lock descriptor closes when unlock fails", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, descriptor_fault_script("unlock"))

    assert result["fd_delta"] == 0
    assert Enum.all?(result["results"], &is_nil/1)
  end

  test "activation state with an invalid Memory session ID is ignored", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import establish, resolve

      claude_id = "claude-invalid-memory-id"
      establish(claude_id, "startup")
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      record_path = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks" / f"{digest}.json"
      record_path.write_text(json.dumps({
          "version": 1,
          "claude_session_sha256": digest,
          "memory_session_id": "",
      }), encoding="utf-8")

      print(json.dumps({"resolved_id": resolve(claude_id)}))
      """)

    assert result["resolved_id"] == nil
  end

  test "oversized activation state is ignored", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import establish, resolve

      claude_id = "claude-oversized-state"
      establish(claude_id, "startup")
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      record_path = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks" / f"{digest}.json"
      record_path.write_bytes(b"x" * 2049)

      print(json.dumps({"resolved_id": resolve(claude_id)}))
      """)

    assert result["resolved_id"] == nil
  end

  test "invalid Claude IDs return no activation without raising", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import establish, prepare_end, resolve

      nul_id = "claude" + chr(0) + "session"
      oversized_id = "x" * 513

      print(json.dumps({
          "nul_establish": establish(nul_id, "startup"),
          "nul_resolve": resolve(nul_id),
          "nul_prepare": prepare_end(nul_id),
          "oversized_establish": establish(oversized_id, "startup"),
          "oversized_resolve": resolve(oversized_id),
          "oversized_prepare": prepare_end(oversized_id),
      }))
      """)

    assert Enum.all?(result, fn {_action, activation_id} -> is_nil(activation_id) end)
  end

  test "Claude ID bounds count UTF-8 bytes", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import establish, prepare_end, resolve

      valid_id = "界" * 170
      oversized_id = "界" * 171

      print(json.dumps({
          "valid_establish": establish(valid_id, "startup"),
          "valid_resolve": resolve(valid_id),
          "oversized_establish": establish(oversized_id, "startup"),
          "oversized_resolve": resolve(oversized_id),
          "oversized_prepare": prepare_end(oversized_id),
      }))
      """)

    assert result["valid_establish"] == String.duplicate("界", 170)
    assert result["valid_resolve"] == result["valid_establish"]
    assert result["oversized_establish"] == nil
    assert result["oversized_resolve"] == nil
    assert result["oversized_prepare"] == nil
  end

  test "missing and unsupported activation sources return no mapping", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import establish, resolve

      claude_id = "claude-invalid-source"

      print(json.dumps({
          "missing": establish(claude_id, None),
          "unsupported": establish(claude_id, "reconnect"),
          "non_string": establish(claude_id, []),
          "resolved_id": resolve(claude_id),
      }))
      """)

    assert Enum.all?(result, fn {_action, activation_id} -> is_nil(activation_id) end)
  end

  test "clear identity maps a new Claude ID without inheriting the old activation", %{
    tmp_dir: tmp_dir
  } do
    result =
      run_activation_session(tmp_dir, """
      import json
      from activation_session import establish, resolve

      old_claude_id = "claude-before-clear"
      new_claude_id = "claude-after-clear"
      old_memory_id = establish(old_claude_id, "resume")
      clear_memory_id = establish(new_claude_id, "clear")

      print(json.dumps({
          "old_memory_id": old_memory_id,
          "clear_memory_id": clear_memory_id,
          "old_resolved_id": resolve(old_claude_id),
          "new_resolved_id": resolve(new_claude_id),
      }))
      """)

    assert result["clear_memory_id"] == "claude-after-clear"
    assert result["new_resolved_id"] == "claude-after-clear"
    assert result["old_resolved_id"] == result["old_memory_id"]
    refute result["new_resolved_id"] == result["old_resolved_id"]
  end

  test "TMPDIR fallback uses a private UID-scoped state root", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(
        tmp_dir,
        """
        import hashlib
        import json
        import os
        from pathlib import Path
        from activation_session import establish, resolve

        claude_id = "claude-tmpdir-fallback"
        memory_id = establish(claude_id, "startup")
        digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
        state_root = Path(os.environ["TMPDIR"]) / f"backplane-memory-hooks-{os.getuid()}"
        record_path = state_root / f"{digest}.json"

        print(json.dumps({
            "memory_id": memory_id,
            "resolved_id": resolve(claude_id),
            "root_name": state_root.name,
            "root_mode": state_root.stat().st_mode & 0o777,
            "record_exists": record_path.is_file(),
        }))
        """,
        xdg_runtime?: false
      )

    assert result["memory_id"] == "claude-tmpdir-fallback"
    assert result["resolved_id"] == result["memory_id"]
    assert result["root_name"] =~ ~r/^backplane-memory-hooks-\d+$/
    assert result["root_mode"] == 0o700
    assert result["record_exists"]
  end

  test "a symlink state root is rejected", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import json
      import os
      from pathlib import Path
      from activation_session import establish

      runtime_root = Path(os.environ["XDG_RUNTIME_DIR"])
      target_root = runtime_root / "target-root"
      target_root.mkdir(mode=0o700)
      (runtime_root / "backplane-memory-hooks").symlink_to(target_root, target_is_directory=True)

      print(json.dumps({"memory_id": establish("claude-symlink-root", "startup")}))
      """)

    assert result["memory_id"] == nil
  end

  test "a symlink activation record is rejected", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import resolve

      claude_id = "claude-symlink-record"
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      state_root = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks"
      state_root.mkdir(mode=0o700)
      target_record = Path(os.environ["XDG_RUNTIME_DIR"]) / "target-record.json"
      target_record.write_text(json.dumps({
          "version": 1,
          "claude_session_sha256": digest,
          "memory_session_id": "forged-memory-session",
      }), encoding="utf-8")
      (state_root / f"{digest}.json").symlink_to(target_record)

      print(json.dumps({"resolved_id": resolve(claude_id)}))
      """)

    assert result["resolved_id"] == nil
  end

  test "a symlink activation lock is rejected", %{tmp_dir: tmp_dir} do
    result =
      run_activation_session(tmp_dir, """
      import hashlib
      import json
      import os
      from pathlib import Path
      from activation_session import establish

      claude_id = "claude-symlink-lock"
      digest = hashlib.sha256(claude_id.encode("utf-8")).hexdigest()
      state_root = Path(os.environ["XDG_RUNTIME_DIR"]) / "backplane-memory-hooks"
      state_root.mkdir(mode=0o700)
      target_lock = Path(os.environ["XDG_RUNTIME_DIR"]) / "target-lock"
      target_lock.touch(mode=0o600)
      (state_root / f"{digest}.lock").symlink_to(target_lock)

      print(json.dumps({"memory_id": establish(claude_id, "startup")}))
      """)

    assert result["memory_id"] == nil
  end

  test "a regular-file runtime path returns no activation without raising", %{tmp_dir: tmp_dir} do
    runtime_file = Path.join(tmp_dir, "runtime-file")
    File.write!(runtime_file, "not a directory")

    result =
      run_activation_session(
        tmp_dir,
        """
        import json
        from activation_session import establish, prepare_end, resolve

        claude_id = "claude-invalid-runtime"

        print(json.dumps({
            "startup_id": establish(claude_id, "startup"),
            "compact_id": establish(claude_id, "compact"),
            "resolved_id": resolve(claude_id),
            "end_token": prepare_end(claude_id),
        }))
        """,
        runtime_dir: runtime_file,
        create_runtime_dir?: false
      )

    assert Enum.all?(result, fn {_action, activation_id} -> is_nil(activation_id) end)
  end
end
