defmodule Backplane.CDP.MCP.Observer do
  @moduledoc """
  Session-owned page connection collecting bounded console and network summaries.

  Network records contain identifiers, URL, method, resource type and status.
  Headers, cookies and bodies are discarded at event admission.
  """
  use GenServer

  alias Backplane.CDP.Client
  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event

  @limit 500
  @text_limit 4_096
  @opening_timeout 5_000

  def start(port, target, owner \\ self()) do
    with {:ok, url} <- Client.page_socket_url(port, target),
         {:ok, pid} <- GenServer.start(__MODULE__, {url, owner}) do
      case request(pid, :ready, @opening_timeout + 1_000) do
        :ok ->
          {:ok, pid}

        {:error, message} ->
          stop(pid)
          {:error, message}
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Chrome page observer could not connect"}
    end
  end

  def command(pid, method, params, timeout \\ 15_000),
    do: request(pid, {:command, method, params, timeout}, timeout + 1_000)

  def watch_logpoints(pid, entries), do: request(pid, {:watch_logpoints, entries}, 5000)
  def watched_logpoints(pid), do: request(pid, :watched_logpoints, 5000)
  def scripts(pid), do: request(pid, :scripts, 5_000)
  def data(pid), do: request(pid, :data, 5_000)
  def script_dialog(pid, action), do: request(pid, {:script_dialog, action}, 5_000)
  def before_unload(pid, action), do: request(pid, {:before_unload, action}, 5_000)

  def wait_event(pid, "Tracing.tracingComplete", timeout),
    do: request(pid, {:wait_event, "Tracing.tracingComplete", timeout}, timeout + 1_000)

  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp request(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, _reason -> {:error, "Chrome page observer is unavailable"}
  end

  @impl true
  def init({url, owner}) do
    owner_monitor = Process.monitor(owner)

    case WebSocket.new(url, [],
           delivery: :ack,
           telemetry_url: nil,
           opening_timeout: @opening_timeout,
           close_timeout: 500,
           max_message_size: 2_097_152,
           max_queue_bytes: 4_194_304,
           max_queue_events: 128
         ) do
      %WebSocket{} = socket ->
        timer = Process.send_after(self(), :opening_timeout, @opening_timeout)

        {:ok,
         %{
           socket: socket,
           owner_monitor: owner_monitor,
           owner: owner,
           watched_logpoints: [],
           refresh_scheduled: false,
           script_hashes: %{},
           timer: timer,
           ready: false,
           waiters: [],
           enabling: 0,
           next_command: 1,
           pending: %{},
           event_waiters: %{},
           events: %{},
           console: [],
           network: [],
           scripts: %{},
           map_bytes: 0,
           next_console: 1,
           next_network: 1,
           generation: 0,
           loader: nil,
           dialog: nil,
           script_dialog: nil,
           before_unload: nil,
           handled_before_unload: nil
         }}

      {:error, _reason} ->
        {:stop, :normal}
    end
  end

  @impl true
  def handle_call(:ready, _from, %{ready: true} = state), do: {:reply, :ok, state}
  def handle_call(:ready, from, state), do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:watched_logpoints, _from, state),
    do: {:reply, {:ok, state.watched_logpoints}, state}

  def handle_call({:watch_logpoints, entries}, _from, state),
    do: {:reply, :ok, %{state | watched_logpoints: entries}}

  def handle_call(:scripts, _from, state), do: {:reply, {:ok, state.scripts}, state}

  def handle_call(:data, _from, state) do
    {:reply,
     {:ok, Map.take(state, [:console, :network, :generation, :dialog, :handled_before_unload])},
     state}
  end

  def handle_call({:script_dialog, action}, _from, state) do
    if action == nil or state.dialog == nil do
      {:reply, :ok, %{state | script_dialog: action}}
    else
      {:reply, {:error, "An open dialog is blocking evaluation. Call handle_dialog."}, state}
    end
  end

  def handle_call({:before_unload, action}, _from, state) do
    handled = if action == nil, do: state.handled_before_unload, else: nil
    {:reply, :ok, %{state | before_unload: action, handled_before_unload: handled}}
  end

  def handle_call({:command, method, params, timeout}, from, state) do
    if state.ready do
      {:noreply, send_command(state, method, params, from, timeout)}
    else
      {:reply, {:error, "Chrome page observer is connecting"}, state}
    end
  end

  def handle_call({:wait_event, method, timeout}, from, state) do
    case Map.pop(state.events, method) do
      {nil, _events} ->
        timer = Process.send_after(self(), {:event_timeout, method}, timeout)
        {:noreply, %{state | event_waiters: Map.put(state.event_waiters, method, {from, timer})}}

      {params, events} ->
        {:reply, {:ok, params}, %{state | events: events}}
    end
  end

  @impl true
  def handle_info({WebSocket, socket, %Event.Open{}}, %{socket: socket} = state) do
    state = %{state | enabling: 3}
    state = send_command(state, "Page.enable", %{}, :enable, @opening_timeout)
    state = send_command(state, "Runtime.enable", %{}, :enable, @opening_timeout)

    state =
      send_command(state, "Network.enable", %{"maxPostDataSize" => 0}, :enable, @opening_timeout)

    {:noreply, state}
  end

  def handle_info({WebSocket, socket, %Event.Message{data: data}, ref}, %{socket: socket} = state) do
    WebSocket.acknowledge(socket, ref)

    case Formata.JSON.decode(data) do
      {:ok, %{"id" => id} = result} -> handle_response(id, result, state)
      {:ok, %{"method" => method, "params" => params}} -> {:noreply, event(method, params, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({WebSocket, socket, %Event.Close{}}, %{socket: socket} = state),
    do: {:stop, :normal, fail_pending(state, "Chrome page observer disconnected")}

  def handle_info({WebSocket, socket, %Event.Error{}}, %{socket: socket} = state),
    do: {:stop, :normal, fail_pending(state, "Chrome page observer failed")}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(:opening_timeout, %{ready: false} = state),
    do: {:stop, :normal, fail_pending(state, "Chrome page observer connection timed out")}

  def handle_info(:opening_timeout, state), do: {:noreply, state}

  def handle_info({:command_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{:enable, _timer}, pending} ->
        {:stop, :normal,
         fail_pending(
           %{state | pending: pending},
           "Chrome page observer initialization timed out"
         )}

      {{from, _timer}, pending} ->
        reply(from, {:error, "Chrome page command timed out"})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:event_timeout, method}, state) do
    case Map.pop(state.event_waiters, method) do
      {nil, _waiters} ->
        {:noreply, state}

      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, "Chrome event timed out"})
        {:noreply, %{state | event_waiters: waiters}}
    end
  end

  def handle_info(:refresh_logpoints, state) do
    if state.watched_logpoints != [], do: send(state.owner, {:refresh_logpoints, self()})
    {:noreply, %{state | refresh_scheduled: false}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    fail_pending(state, "Chrome page observer closed")
    WebSocket.close(state.socket)
    HTTP.ClientCompletion.await(WebSocket.completion(state.socket), 1_000)
    :ok
  end

  defp send_command(state, method, params, from, timeout) do
    id = state.next_command
    timer = Process.send_after(self(), {:command_timeout, id}, timeout)
    message = Formata.JSON.encode!(%{"id" => id, "method" => method, "params" => params})

    case WebSocket.send(state.socket, message) do
      :ok ->
        events =
          if method == "Tracing.start",
            do: Map.delete(state.events, "Tracing.tracingComplete"),
            else: state.events

        %{
          state
          | next_command: id + 1,
            pending: Map.put(state.pending, id, {from, timer}),
            events: events
        }

      {:error, _reason} ->
        Process.cancel_timer(timer)
        reply(from, {:error, "Chrome page command could not be sent"})
        state
    end
  end

  defp handle_response(id, response, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        state = %{state | pending: pending}

        result =
          case response do
            %{"result" => result} -> {:ok, result}
            %{"error" => %{"message" => message}} -> {:error, "Chrome protocol error: #{message}"}
            _ -> {:error, "Invalid Chrome protocol response"}
          end

        if from == :enable do
          case result do
            {:ok, _result} ->
              state = %{state | enabling: state.enabling - 1}

              if state.enabling == 0 do
                Process.cancel_timer(state.timer)
                Enum.each(state.waiters, &GenServer.reply(&1, :ok))
                {:noreply, %{state | ready: true, waiters: []}}
              else
                {:noreply, state}
              end

            {:error, message} ->
              {:stop, :normal, fail_pending(state, message)}
          end
        else
          reply(from, result)
          {:noreply, state}
        end
    end
  end

  defp reply(:enable, _result), do: :ok
  defp reply(:discard, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)

  defp fail_pending(state, message) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, message}))

    Enum.each(state.pending, fn {_id, {from, timer}} ->
      Process.cancel_timer(timer)
      reply(from, {:error, message})
    end)

    Enum.each(state.event_waiters, fn {_method, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, message})
    end)

    %{state | pending: %{}, waiters: [], event_waiters: %{}}
  end

  defp event("Runtime.executionContextsCleared", _params, state),
    do: %{state | scripts: %{}, script_hashes: %{}, map_bytes: 0}

  defp event("Debugger.scriptParsed", %{"url" => url} = script, state)
       when is_binary(url) and byte_size(url) <= 4096 do
    if (map_size(state.scripts) < 2000 or Map.has_key?(state.scripts, url)) and
         String.starts_with?(url, ["https://", "http://"]) do
      ref = script["sourceMapURL"]
      bytes = state.map_bytes - byte_size(state.scripts[url] || "")

      ref =
        if is_binary(ref) and byte_size(ref) <= 720_000 and bytes + byte_size(ref) <= 4_194_304,
          do: ref

      hash = script["hash"]

      changed =
        not Map.has_key?(state.scripts, url) or state.script_hashes[url] != hash or
          state.scripts[url] != ref

      state = %{
        state
        | scripts: Map.put(state.scripts, url, ref),
          script_hashes: Map.put(state.script_hashes, url, hash),
          map_bytes: bytes + byte_size(ref || "")
      }

      if ref not in [nil, ""] and changed and state.watched_logpoints != [] and
           not state.refresh_scheduled do
        Process.send_after(self(), :refresh_logpoints, 150)
        %{state | refresh_scheduled: true}
      else
        state
      end
    else
      state
    end
  end

  defp event("Runtime.consoleAPICalled", params, state) do
    args = params["args"] || []

    {values, _budget} =
      Enum.map_reduce(Enum.take(args, 32), @text_limit, fn arg, budget ->
        value = String.slice(remote_value(arg), 0, budget)
        {value, max(budget - String.length(value), 0)}
      end)

    entry = %{
      id: state.next_console,
      type: console_type(params["type"]),
      text: limited(Enum.join(values, " ")),
      args: values,
      args_count: length(args),
      stack: stack(params["stackTrace"]),
      generation: state.generation
    }

    %{state | console: bounded(state.console ++ [entry]), next_console: state.next_console + 1}
  end

  defp event("Runtime.exceptionThrown", %{"exceptionDetails" => details}, state) do
    exception = details["exception"] || %{}
    text = exception["description"] || details["text"] || "Uncaught exception"

    entry = %{
      id: state.next_console,
      type: "error",
      text: limited(text),
      args: [],
      args_count: 0,
      stack: stack(details["stackTrace"]),
      generation: state.generation
    }

    %{state | console: bounded(state.console ++ [entry]), next_console: state.next_console + 1}
  end

  defp event("Page.frameNavigated", %{"frame" => frame}, state) do
    if frame["parentId"] == nil and frame["loaderId"] != state.loader do
      %{state | loader: frame["loaderId"], generation: state.generation + 1}
    else
      state
    end
  end

  defp event("Network.requestWillBeSent", params, state) do
    request = params["request"] || %{}

    generation =
      if params["type"] == "Document" and params["loaderId"] != state.loader,
        do: state.generation + 1,
        else: state.generation

    entry = %{
      id: state.next_network,
      cdp_id: params["requestId"],
      url: safe_url(request["url"]),
      method: limited(request["method"] || "GET"),
      resource_type: String.downcase(params["type"] || "Other"),
      status: "pending",
      generation: generation
    }

    %{state | network: bounded(state.network ++ [entry]), next_network: state.next_network + 1}
  end

  defp event("Network.responseReceived", params, state) do
    status = get_in(params, ["response", "status"])
    status = if is_number(status), do: "#{trunc(status)}", else: "pending"
    update_request(state, params["requestId"], status)
  end

  defp event("Network.loadingFailed", params, state),
    do:
      update_request(state, params["requestId"], limited(params["errorText"] || "request failed"))

  defp event("Page.javascriptDialogOpening", params, state) do
    dialog = Map.take(params, ~w(type message defaultPrompt))
    state = %{state | dialog: dialog}

    cond do
      dialog["type"] == "beforeunload" and state.before_unload in ["accept", "dismiss"] ->
        send_command(
          %{state | handled_before_unload: state.before_unload},
          "Page.handleJavaScriptDialog",
          %{"accept" => state.before_unload == "accept"},
          :discard,
          5000
        )

      is_binary(state.script_dialog) ->
        action = state.script_dialog
        params = %{"accept" => action != "dismiss"}

        params =
          if dialog["type"] == "prompt" and action not in ["accept", "dismiss"],
            do: Map.put(params, "promptText", action),
            else: params

        send_command(state, "Page.handleJavaScriptDialog", params, :discard, 5000)

      true ->
        state
    end
  end

  defp event("Page.javascriptDialogClosed", _params, state), do: %{state | dialog: nil}

  defp event("Tracing.tracingComplete" = method, params, state) do
    event = Map.take(params, ~w(dataLossOccurred stream traceFormat streamCompression))

    case Map.pop(state.event_waiters, method) do
      {nil, _waiters} ->
        %{state | events: Map.put(state.events, method, event)}

      {{from, timer}, waiters} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, event})
        %{state | event_waiters: waiters}
    end
  end

  defp event(_method, _params, state), do: state

  defp update_request(state, cdp_id, status) do
    newest = state.network |> Enum.reverse() |> Enum.find(&(&1.cdp_id == cdp_id))

    if newest do
      %{
        state
        | network:
            Enum.map(state.network, fn entry ->
              if entry.id == newest.id, do: %{entry | status: status}, else: entry
            end)
      }
    else
      state
    end
  end

  defp remote_value(%{"value" => value}) when is_binary(value), do: limited(value)
  defp remote_value(%{"value" => value}), do: limited(Formata.JSON.encode!(value))

  defp remote_value(value),
    do:
      limited(
        value["unserializableValue"] || value["description"] || value["type"] || "undefined"
      )

  defp console_type("warning"), do: "warn"
  defp console_type(type) when is_binary(type), do: type
  defp console_type(_type), do: "log"

  defp stack(%{"callFrames" => frames}),
    do:
      Enum.take(frames, 20)
      |> Enum.map(fn frame ->
        Map.take(frame, ~w(functionName url lineNumber columnNumber))
        |> Map.update("url", "", &safe_url/1)
      end)

  defp stack(_stack), do: []
  defp bounded(entries), do: Enum.take(entries, -@limit)
  defp limited(text) when is_binary(text), do: String.slice(text, 0, @text_limit)
  defp limited(_text), do: ""

  defp safe_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> limited(URI.to_string(%{uri | userinfo: nil}))
      _ -> limited(url)
    end
  end

  defp safe_url(_url), do: ""
end
