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

  test "activation state with the wrong version is ignored", %{tmp_dir: tmp_dir} do
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
      record_path.write_text(json.dumps({
          "version": 2,
          "claude_session_sha256": digest,
          "memory_session_id": "forged-memory-session",
      }), encoding="utf-8")

      print(json.dumps({"resolved_id": resolve(claude_id)}))
      """)

    assert result["resolved_id"] == nil
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
