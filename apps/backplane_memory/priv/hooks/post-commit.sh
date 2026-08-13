#!/usr/bin/env bash
# Claude Code hook: PostToolUse (Bash matcher, actual git commits only)

[ "${AGENTMEMORY_SDK_CHILD:-}" = "1" ] && exit 0

CAPTURE_URL="${BACKPLANE_HOST_AGENT_URL:-http://127.0.0.1:4222}"
HOOKS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

python3 -c '
import json
import os
import re
import shlex
import sys
sys.path.insert(0, sys.argv[1])
from activation_session import resolve, send_json

def display(value):
    if isinstance(value, str):
        return value
    if value is None:
        return ""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

def heredoc_specs(command_line):
    strip_token = "__BACKPLANE_HOOK_HEREDOC_STRIP__"
    while strip_token in command_line:
        strip_token += "_"

    transformed_command = []
    quote = None
    index = 0
    while index < len(command_line):
        char = command_line[index]

        if char == "\\" and quote != chr(39) and index + 1 < len(command_line):
            transformed_command.extend((char, command_line[index + 1]))
            index += 2
            continue

        if (
            quote is None
            and command_line.startswith("<<-", index)
            and (index == 0 or command_line[index - 1] != "<")
        ):
            transformed_command.extend(("<< ", strip_token, " "))
            index += 3
            continue

        transformed_command.append(char)
        if quote is None and char in (chr(39), chr(34)):
            quote = char
        elif char == quote:
            quote = None
        index += 1

    lexer = shlex.shlex(
        "".join(transformed_command), posix=True, punctuation_chars=";&|()<>"
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
        if token == "<<" and index + 1 < len(tokens):
            delimiter_index = index + 1
            strip_tabs = tokens[delimiter_index] == strip_token
            if strip_tabs:
                delimiter_index += 1
            if delimiter_index < len(tokens):
                specs.append((tokens[delimiter_index], strip_tabs))
            index = delimiter_index + 1
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

session_id = resolve(data.get("session_id"))
tool_output = data.get("tool_response")
content = display(tool_output)
if session_id is None or not content:
    sys.exit(0)

data["session_id"] = session_id
send_json(sys.argv[2], "/capture/v1/hooks/claude_code/PostCommit", data)
' "$HOOKS_DIR" "$CAPTURE_URL" >/dev/null 2>&1 || true

exit 0
