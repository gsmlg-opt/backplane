#!/usr/bin/env bash
# Claude Code hook: PostToolUse (Bash matcher, actual git commits only)

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

MEMORY_URL="${BACKPLANE_MEMORY_URL:-http://localhost:4220}"

BODY="$(python3 -c '
import json
import os
import re
import shlex
import sys

def display(value):
    if isinstance(value, str):
        return value
    if value is None:
        return ""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

def heredoc_specs(command_line):
    lexer = shlex.shlex(
        command_line, posix=True, punctuation_chars=";&|()<>-"
    )
    lexer.commenters = ""
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True

    try:
        tokens = list(lexer)
    except ValueError:
        return []

    specs = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in ("<<", "<<-") and index + 1 < len(tokens):
            specs.append((tokens[index + 1], token == "<<-"))
            index += 2
        else:
            index += 1

    return specs

def shell_segments(command):
    newline_token = "__BACKPLANE_HOOK_NEWLINE__"
    while newline_token in command:
        newline_token += "_"

    heredoc_token = "__BACKPLANE_HOOK_HEREDOC__"
    while heredoc_token in command or heredoc_token == newline_token:
        heredoc_token += "_"

    processed_command = []
    logical_line = []
    quote = None
    word_start = True
    index = 0
    while index < len(command):
        char = command[index]

        if char == "\\" and quote != chr(39) and index + 1 < len(command):
            following = command[index + 1]
            if following == "\n":
                index += 2
                continue
            processed_command.extend((char, following))
            logical_line.extend((char, following))
            word_start = False
            index += 2
            continue

        if char == "#" and quote is None and word_start:
            line_end = command.find("\n", index)
            if line_end == -1:
                break
            index = line_end
            continue

        if char == "\n" and quote is None:
            processed_command.extend((" ", newline_token, " "))
            pending_heredocs = heredoc_specs("".join(logical_line))
            logical_line = []
            word_start = True
            index += 1

            for delimiter, strip_tabs in pending_heredocs:
                terminator_found = False
                while index < len(command):
                    line_end = command.find("\n", index)
                    if line_end == -1:
                        line = command[index:]
                        index = len(command)
                    else:
                        line = command[index:line_end]
                        index = line_end + 1

                    candidate = line.lstrip("\t") if strip_tabs else line
                    if candidate == delimiter:
                        processed_command.extend((" ", heredoc_token, " "))
                        if line_end != -1:
                            processed_command.extend((" ", newline_token, " "))
                        terminator_found = True
                        break

                if not terminator_found:
                    processed_command.extend((" ", heredoc_token, " "))
                    break

            continue
        else:
            processed_command.append(char)
            logical_line.append(char)
            if quote is None and char in (chr(39), chr(34)):
                quote = char
                word_start = False
            elif char == quote:
                quote = None
            elif quote is None:
                word_start = char in " \t\r;&|()<>"
        index += 1

    lexer = shlex.shlex(
        "".join(processed_command), posix=True, punctuation_chars=";&|()<>"
    )
    lexer.commenters = ""
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True

    try:
        tokens = list(lexer)
    except ValueError:
        return []

    segments = []
    current = []
    expect_heredoc = False

    for token in tokens:
        if expect_heredoc:
            expect_heredoc = False
            continue

        if token in ("<<", "<<-"):
            expect_heredoc = True
            continue

        if token == newline_token:
            if current:
                segments.append(current)
                current = []
            expect_heredoc = False
            continue

        if token and all(char in ";&|()" for char in token):
            if current:
                segments.append(current)
                current = []
            continue

        current.append(token)

    if current:
        segments.append(current)

    return segments

def strip_command_prefix(tokens):
    assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
    index = 0

    while index < len(tokens) and assignment.match(tokens[index]):
        index += 1

    while index < len(tokens):
        command = os.path.basename(tokens[index])
        if command == "env":
            index += 1
            while index < len(tokens) and (tokens[index].startswith("-") or assignment.match(tokens[index])):
                index += 1
            continue
        if command in ("command", "sudo", "time"):
            index += 1
            while index < len(tokens) and tokens[index].startswith("-"):
                index += 1
            continue
        break

    return tokens[index:]

def is_git_commit(tokens):
    tokens = strip_command_prefix(tokens)
    if not tokens or os.path.basename(tokens[0]) != "git":
        return False

    index = 1
    options_with_values = {
        "-C",
        "-c",
        "--config-env",
        "--exec-path",
        "--git-dir",
        "--namespace",
        "--super-prefix",
        "--work-tree",
    }

    while index < len(tokens):
        token = tokens[index]
        if token == "commit":
            return True
        if token in options_with_values:
            index += 2
            continue
        if token.startswith("-c") and token != "-c":
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return False

    return False

def contains_git_commit(command):
    return any(is_git_commit(segment) for segment in shell_segments(command))

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
    sys.exit(0)

tool_input = data.get("tool_input")
command = tool_input.get("command") if isinstance(tool_input, dict) else None
if not isinstance(command, str) or not contains_git_commit(command):
    sys.exit(0)

session_id = data.get("session_id")
tool_output = data.get("tool_response")
content = display(tool_output)
if not isinstance(session_id, str) or not session_id or not content:
    sys.exit(0)

payload = {"tool_input": tool_input, "tool_output": tool_output}
tool_use_id = data.get("tool_use_id")
if isinstance(tool_use_id, str) and tool_use_id:
    payload["tool_use_id"] = tool_use_id

duration_ms = data.get("duration_ms")
if isinstance(duration_ms, (int, float)) and not isinstance(duration_ms, bool):
    payload["duration_ms"] = duration_ms

body = {
    "session_id": session_id,
    "project": data.get("cwd") or data.get("project") or "",
    "content": content,
    "tool_name": "git_commit",
    "is_error": False,
    "event_type": "tool.call.completed",
    "payload": payload,
}
agent_id = data.get("agent_id")
if isinstance(agent_id, str) and agent_id:
    body["agent_id"] = agent_id
if isinstance(tool_use_id, str) and tool_use_id:
    body["idempotency_key"] = f"claude:git_commit:{session_id}:{tool_use_id}"

sys.stdout.write(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
' 2>/dev/null || true)"

[ -n "$BODY" ] || exit 0

printf '%s' "$BODY" | curl -sf -m 2.0 -X POST "$MEMORY_URL/api/memory/observations" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  >/dev/null 2>&1 || true

exit 0
