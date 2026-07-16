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

def shell_segments(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>\n")
    lexer.commenters = ""
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True

    try:
        tokens = list(lexer)
    except ValueError:
        return []

    segments = []
    current = []
    pending_heredocs = []
    heredoc = None
    heredoc_line = []
    expect_heredoc = False

    for token in tokens:
        if heredoc is not None:
            if token == "\n":
                if heredoc_line == [heredoc]:
                    heredoc = pending_heredocs.pop(0) if pending_heredocs else None
                heredoc_line = []
            else:
                heredoc_line.append(token)
            continue

        if expect_heredoc:
            pending_heredocs.append(token)
            expect_heredoc = False
            continue

        if token in ("<<", "<<-"):
            expect_heredoc = True
            continue

        if token == "\n":
            if current:
                segments.append(current)
                current = []
            if pending_heredocs:
                heredoc = pending_heredocs.pop(0)
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
