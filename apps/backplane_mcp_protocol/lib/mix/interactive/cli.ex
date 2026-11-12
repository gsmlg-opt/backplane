defmodule Mix.Interactive.CLI do
  @moduledoc false

  alias Mix.Interactive.UI

  def check_client_connection(client, attempt \\ 5)

  def check_client_connection(_client, attempt) when attempt <= 0 do
    IO.puts("#{UI.colors().error}✗ Server connection not established#{UI.colors().reset}")

    IO.puts("#{UI.colors().info}Use the 'initialize' command to retry connection#{UI.colors().reset}")
  end

  def check_client_connection(client, attempt) do
    :timer.sleep(200 * attempt)

    if cap = Backplane.McpProtocol.Client.get_server_capabilities(client) do
      IO.puts("#{UI.colors().info}Server capabilities: #{inspect(cap, pretty: true)}#{UI.colors().reset}")

      IO.puts("#{UI.colors().success}✓ Successfully connected to server#{UI.colors().reset}")
    else
      IO.puts("#{UI.colors().warning}! Waiting for server connection...#{UI.colors().reset}")

      check_client_connection(client, attempt - 1)
    end
  end

  def check_sse_connection(sse, attempt \\ 3)

  def check_sse_connection(_sse, attempt) when attempt <= 0 do
    IO.puts("#{UI.colors().error}✗ SSE connection not established#{UI.colors().reset}")

    IO.puts("#{UI.colors().info}Use the 'initialize' command to retry connection#{UI.colors().reset}")
  end

  def check_sse_connection(sse, attempt) do
    :timer.sleep(500)

    state = :sys.get_state(sse)

    if state[:message_url] == nil do
      IO.puts("#{UI.colors().warning}! Waiting for server connection...#{UI.colors().reset}")

      check_sse_connection(sse, attempt - 1)
    else
      IO.puts(
        "#{UI.colors().info}SSE connection:\n\s\s- sse stream url: #{state[:sse_url]}\n\s\s- message url: #{state[:message_url]}#{UI.colors().reset}"
      )

      IO.puts("#{UI.colors().success}✓ Successfully connected via SSE#{UI.colors().reset}")
    end
  end

  def check_websocket_connection(ws, attempt \\ 3)

  def check_websocket_connection(_ws, attempt) when attempt <= 0 do
    IO.puts("#{UI.colors().error}✗ WebSocket connection not established#{UI.colors().reset}")

    IO.puts("#{UI.colors().info}Use the 'initialize' command to retry connection#{UI.colors().reset}")
  end

  def check_websocket_connection(ws, attempt) do
    :timer.sleep(500)

    state = :sys.get_state(ws)

    if state[:stream_ref] == nil do
      IO.puts("#{UI.colors().warning}! Waiting for server connection...#{UI.colors().reset}")

      check_websocket_connection(ws, attempt - 1)
    else
      IO.puts("#{UI.colors().info}WebSocket connection:\n\s\s- ws url: #{state[:ws_url]}#{UI.colors().reset}")

      IO.puts("#{UI.colors().success}✓ Successfully connected via WebSocket#{UI.colors().reset}")
    end
  end

  def check_streamable_http_connection(http, attempt \\ 3)

  def check_streamable_http_connection(_http, attempt) when attempt <= 0 do
    IO.puts("#{UI.colors().error}✗ StreamableHTTP connection not established#{UI.colors().reset}")

    IO.puts("#{UI.colors().info}Use the 'initialize' command to retry connection#{UI.colors().reset}")
  end

  def check_streamable_http_connection(http, attempt) do
    :timer.sleep(500)

    state = :sys.get_state(http)

    if state[:message_url] == nil do
      IO.puts("#{UI.colors().warning}! Waiting for server connection...#{UI.colors().reset}")

      check_streamable_http_connection(http, attempt - 1)
    else
      IO.puts(
        "#{UI.colors().info}StreamableHTTP connection:\n\s\s- base url: #{state[:base_url]}\n\s\s- message url: #{state[:message_url]}#{UI.colors().reset}"
      )

      IO.puts("#{UI.colors().success}✓ Successfully connected via StreamableHTTP#{UI.colors().reset}")
    end
  end

end
