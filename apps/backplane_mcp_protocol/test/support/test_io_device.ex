defmodule TestIODevice do
  @moduledoc """
  Minimal Erlang IO-protocol server for exercising `Backplane.McpProtocol.Server.Transport.STDIO` in tests.

  Input lines can be queued deterministically with `push_line/2`. A single pending
  reader is retained while the queue is empty, mirroring a live stdin. Write requests
  are buffered and can be retrieved via `contents/1`.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @spec contents(GenServer.server()) :: binary()
  def contents(device) do
    GenServer.call(device, :contents)
  end

  @spec push_line(GenServer.server(), binary() | :eof | {:error, term()}) :: :ok
  def push_line(device, line) when is_binary(line) or line == :eof do
    GenServer.call(device, {:push_line, line})
  end

  def push_line(device, {:error, _reason} = error) do
    GenServer.call(device, {:push_line, error})
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{output: [], input: :queue.new(), pending_reader: nil}}
  end

  @impl GenServer
  def handle_info({:io_request, from, reply_as, request}, state) do
    handle_io_request(request, from, reply_as, state)
  end

  @impl GenServer
  def handle_call(:contents, _from, state) do
    {:reply, state.output |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  def handle_call({:push_line, line}, _from, %{pending_reader: {from, reply_as}} = state) do
    send(from, {:io_reply, reply_as, normalize_line(line)})
    {:reply, :ok, %{state | pending_reader: nil}}
  end

  def handle_call({:push_line, line}, _from, state) do
    {:reply, :ok, %{state | input: :queue.in(normalize_line(line), state.input)}}
  end

  defp handle_io_request({:put_chars, _encoding, chars}, from, reply_as, state) do
    send(from, {:io_reply, reply_as, :ok})
    {:noreply, %{state | output: [chars | state.output]}}
  end

  defp handle_io_request({:put_chars, chars}, from, reply_as, state) do
    send(from, {:io_reply, reply_as, :ok})
    {:noreply, %{state | output: [chars | state.output]}}
  end

  defp handle_io_request({:put_chars, _encoding, mod, fun, args}, from, reply_as, state) do
    chars = apply(mod, fun, args)
    send(from, {:io_reply, reply_as, :ok})
    {:noreply, %{state | output: [chars | state.output]}}
  end

  defp handle_io_request({:get_line, _encoding, _prompt}, from, reply_as, state) do
    handle_read_request(from, reply_as, state)
  end

  defp handle_io_request({:get_line, _prompt}, from, reply_as, state) do
    handle_read_request(from, reply_as, state)
  end

  defp handle_io_request({:get_chars, _encoding, _prompt, _n}, _from, _reply_as, state), do: {:noreply, state}
  defp handle_io_request({:get_chars, _prompt, _n}, _from, _reply_as, state), do: {:noreply, state}

  defp handle_io_request({:get_until, _encoding, _prompt, _mod, _fun, _args}, _from, _reply_as, state),
    do: {:noreply, state}

  defp handle_io_request({:get_until, _prompt, _mod, _fun, _args}, _from, _reply_as, state), do: {:noreply, state}

  defp handle_io_request({:setopts, _opts}, from, reply_as, state) do
    send(from, {:io_reply, reply_as, :ok})
    {:noreply, state}
  end

  defp handle_io_request(:getopts, from, reply_as, state) do
    send(from, {:io_reply, reply_as, [binary: true, encoding: :utf8]})
    {:noreply, state}
  end

  defp handle_io_request(_other, from, reply_as, state) do
    send(from, {:io_reply, reply_as, {:error, :request}})
    {:noreply, state}
  end

  defp handle_read_request(from, reply_as, state) do
    case :queue.out(state.input) do
      {{:value, line}, input} ->
        send(from, {:io_reply, reply_as, line})
        {:noreply, %{state | input: input}}

      {:empty, _input} when is_nil(state.pending_reader) ->
        {:noreply, %{state | pending_reader: {from, reply_as}}}

      {:empty, _input} ->
        # Some legacy tests attach an additional idle transport to the same
        # device. Keep the original pending reader deterministic and leave the
        # extra reader blocked, matching the previous live-stdin behavior.
        {:noreply, state}
    end
  end

  defp normalize_line(:eof), do: :eof
  defp normalize_line({:error, _reason} = error), do: error
  defp normalize_line(line), do: String.trim_trailing(line, "\n") <> "\n"
end
