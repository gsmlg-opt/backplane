defmodule Backplane.CDP.MCP do
  @moduledoc "Native host-agent implementation of Chrome DevTools MCP tools."

  alias Backplane.CDP
  alias Backplane.CDP.MCP.{Diagnostics, Interaction, Pages, Recording, Session, Styles, Upload}

  alias Backplane.CDP.MCP.{Heap, Lighthouse, Logpoints, Script}

  @external_resource Path.expand("../../../priv/chrome_devtools_mcp/1.14.0.json", __DIR__)
  @pages ~w(list_pages select_page new_page close_page navigate_page resize_page)
  @interaction ~w(take_snapshot take_screenshot click drag fill fill_form hover press_key type_text wait_for)
  @diagnostics ~w(list_console_messages get_console_message get_network_request list_network_requests handle_dialog emulate)
  @recordings ~w(performance_analyze_insight performance_start_trace performance_stop_trace screencast_start screencast_stop)
  @supported @pages ++
               @interaction ++
               @diagnostics ++
               @recordings ++
               ~w(get_css_styles upload_file evaluate_script set_logpoints take_heapsnapshot lighthouse_audit)
  @tools @external_resource
         |> File.read!()
         |> Formata.JSON.decode!()
         |> Enum.filter(&(&1["name"] in @supported))
  @schemas Map.new(@tools, fn tool ->
             {:ok, schema} = Formata.Schema.json_schema(tool["inputSchema"])
             {tool["name"], schema}
           end)

  def tools, do: @tools
  def known?(name), do: is_map_key(@schemas, name)

  def open do
    token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    with {:ok, _pid} <- start({:http, token}), do: {:ok, token}
  end

  def lookup(token) when is_binary(token) do
    with {:ok, port} <- CDP.port(),
         [{pid, _}] <- Registry.lookup(CDP.Registry, {port, {:http, token}}),
         true <- Process.alive?(pid) do
      {:ok, pid}
    else
      _ -> {:error, :unknown_session}
    end
  end

  def lookup(_), do: {:error, :unknown_session}

  def aggregate(agent, name, args) do
    with {:ok, pid} <- start({:aggregate, agent}), do: call(pid, name, args)
  end

  def call(pid, name, args) do
    with {:ok, schema} <- Map.fetch(@schemas, name),
         :ok <- Formata.validate(args, schema) do
      Session.call(pid, name, normalize_numbers(args))
    else
      :error ->
        {:error, "Unknown tool"}

      {:error, [error | _]} ->
        {:error, "Invalid arguments for #{name}: #{Exception.message(error)}"}
    end
  end

  # JSON numbers such as 1 and 1.0 address the same page in the upstream server.
  defp normalize_numbers(n) when is_float(n) and trunc(n) == n, do: trunc(n)

  defp normalize_numbers(args) when is_map(args),
    do: Map.new(args, fn {k, v} -> {k, normalize_numbers(v)} end)

  defp normalize_numbers(list) when is_list(list), do: Enum.map(list, &normalize_numbers/1)
  defp normalize_numbers(value), do: value

  def dispatch(name, args, state) when name in @pages, do: Pages.call(name, args, state)

  def dispatch(name, args, state) when name in @interaction,
    do: Interaction.call(name, args, state)

  def dispatch(name, args, state) when name in @diagnostics,
    do: Diagnostics.call(name, args, state)

  def dispatch(name, args, state) when name in @recordings, do: Recording.call(name, args, state)
  def dispatch("get_css_styles" = name, args, state), do: Styles.call(name, args, state)

  def dispatch("upload_file" = name, args, state), do: Upload.call(name, args, state)

  def dispatch("evaluate_script" = name, args, state), do: Script.call(name, args, state)
  def dispatch("set_logpoints" = name, args, state), do: Logpoints.call(name, args, state)

  def dispatch("take_heapsnapshot" = name, args, state), do: Heap.call(name, args, state)

  def dispatch("lighthouse_audit" = name, args, state), do: Lighthouse.call(name, args, state)

  defp start(key) do
    with {:ok, port} <- CDP.port() do
      case Registry.lookup(CDP.Registry, {port, key}) do
        [{pid, _}] ->
          {:ok, pid}

        [] ->
          case DynamicSupervisor.start_child(CDP.Sessions, {Session, {port, key}}) do
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, :max_children} -> {:error, "Too many active Chrome DevTools sessions"}
            result -> result
          end
      end
    end
  end
end
