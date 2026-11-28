defmodule Backplane.CDP.MCP.Pages do
  @moduledoc """
  Stateful Chrome DevTools MCP page identifiers and page management.
  """

  alias Backplane.CDP.Client
  alias Backplane.CDP.MCP.{Diagnostics, Observer}

  @last_page "The last open page cannot be closed. It is fine to keep it open."
  @default_timeout 30_000

  def call("list_pages", _args, state), do: respond(state)

  def call("select_page", args, state) do
    with {:ok, _pages, state} <- refresh(state),
         {:ok, target, state} <- by_id(args["pageId"], state),
         {:ok, _pid, state} <- Diagnostics.ensure(target, state),
         {:ok, _} <- focus(target, args["bringToFront"], state) do
      respond(%{state | selected: args["pageId"]})
    else
      {:error, message, state} -> {:error, message, state}
      {:error, message} -> {:error, message, state}
    end
  end

  def call("close_page", args, state) do
    with {:ok, _pages, state} <- refresh(state),
         {:ok, target, state} <- by_id(args["pageId"], state) do
      if map_size(state.pages) == 1 do
        respond(state, @last_page)
      else
        case Client.command(state.port, :browser, "Target.closeTarget", %{"targetId" => target}) do
          {:ok, %{"success" => false}} -> {:error, "Unable to close page", state}
          {:ok, _} -> respond(state)
          {:error, message} -> {:error, message, state}
        end
      end
    end
  end

  def call("new_page", args, state) do
    with :ok <- validate_url(args["url"]),
         {:ok, _pages, state} <- refresh(state),
         {:ok, context, state} <- context(args["isolatedContext"], state) do
      params = %{"url" => "about:blank", "background" => args["background"] == true}
      params = if context, do: Map.put(params, "browserContextId", context), else: params

      case Client.command(state.port, :browser, "Target.createTarget", params) do
        {:ok, %{"targetId" => target}} -> finish_new_page(target, args, state)
        {:ok, _} -> {:error, "Chrome did not return a page target", state}
        {:error, message} -> {:error, message, state}
      end
    else
      {:error, message, state} -> {:error, message, state}
      {:error, message} -> {:error, message, state}
    end
  end

  def call("navigate_page", args, state) do
    with :ok <- navigation_args(args),
         {:ok, target, state} <- selected(args, state) do
      type = args["type"] || "url"
      result = navigate(target, type, args, state)

      message =
        case result do
          {:ok, url} -> navigation_success(type, if(type == "url", do: args["url"], else: url))
          {:error, error} -> navigation_failure(type, error)
        end

      message =
        case Observer.data(state.observers[target]) do
          {:ok, %{handled_before_unload: "accept"}} ->
            message <> "\nAccepted a beforeunload dialog."

          {:ok, %{handled_before_unload: "dismiss"}} ->
            message <> "\nDismissed a beforeunload dialog."

          _ ->
            message
        end

      respond(%{state | snapshots: %{}}, message)
    else
      {:error, message, state} -> {:error, message, state}
      {:error, message} -> {:error, message, state}
    end
  end

  def call("resize_page", args, state) do
    with :ok <- dimensions(args),
         {:ok, target, state} <- selected(args, state),
         {:ok, %{"windowId" => window_id, "bounds" => bounds}} <-
           Client.command(state.port, :browser, "Browser.getWindowForTarget", %{
             "targetId" => target
           }),
         {:ok, _} <- normalize_window(window_id, bounds, state),
         {:ok, _} <-
           Client.command(state.port, :browser, "Browser.setContentsSize", %{
             "windowId" => window_id,
             "width" => args["width"],
             "height" => args["height"]
           }) do
      respond(state)
    else
      {:error, message, state} -> {:error, message, state}
      {:error, message} -> {:error, message, state}
      _ -> {:error, "Chrome did not return browser window bounds", state}
    end
  end

  def selected(args, state) do
    with {:ok, _pages, state} <- refresh(state) do
      id = Map.get(args, "pageId", state.selected)

      with {:ok, target, state} <-
             if(id == nil, do: {:error, "No page selected", state}, else: by_id(id, state)),
           {:ok, _pid, state} <- Diagnostics.ensure(target, state) do
        {:ok, target, state}
      end
    end
  end

  def refresh(state) do
    case Client.pages(state.port) do
      {:ok, pages} ->
        pages = Enum.reject(pages, &restricted_page?/1)
        targets = MapSet.new(pages, & &1["id"])

        existing =
          Map.filter(state.pages, fn {_id, target} -> MapSet.member?(targets, target) end)

        known = MapSet.new(existing, fn {_id, target} -> target end)

        {entries, next_id} =
          Enum.reduce(pages, {existing, state.next_id}, fn page, {entries, next_id} ->
            if MapSet.member?(known, page["id"]),
              do: {entries, next_id},
              else: {Map.put(entries, next_id, page["id"]), next_id + 1}
          end)

        info = Map.new(pages, &{&1["id"], &1})
        page_info = Map.new(entries, fn {id, target} -> {id, Map.fetch!(info, target)} end)

        selected =
          if Map.has_key?(entries, state.selected), do: state.selected, else: first_id(entries)

        fallback = state.selected != nil and state.selected != selected

        state =
          state
          |> Map.merge(%{
            pages: entries,
            next_id: next_id,
            selected: selected,
            page_info: page_info
          })
          |> Map.put(:selection_fallback, fallback)
          |> Diagnostics.prune()

        {:ok, pages, state}

      {:error, message} ->
        {:error, message, state}
    end
  end

  def validate_url(url) when is_binary(url), do: validate_url(url, url, 0)
  def validate_url(_url), do: {:error, "A URL is required for navigation of type=url."}

  defp validate_url(url, original, depth) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: "view-source", path: inner}} when depth < 5 ->
        validate_url(inner, original, depth + 1)

      {:ok, %URI{scheme: scheme}} when scheme in ["javascript", "data", "vbscript"] ->
        {:error,
         "Navigating to #{scheme}: URLs is not allowed when JavaScript evaluation is disabled."}

      {:ok, %URI{scheme: "file"}} ->
        {:error, "Navigating to file: URLs is not allowed when --file-navigations is disabled."}

      {:ok, %URI{scheme: "chrome-extension"}} ->
        {:error,
         "Navigating to chrome-extension: URLs is not allowed without --categoryExtensions."}

      {:ok, %URI{scheme: scheme}} when scheme in ["devtools", "chrome-untrusted"] ->
        {:error, "Navigating to #{scheme}: URLs is not allowed."}

      {:ok, %URI{scheme: "chrome", host: host}}
      when host in ["newtab", "new-tab-page", "inspect"] ->
        :ok

      {:ok, %URI{scheme: "about", path: "blank"}} ->
        :ok

      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error,
         "Invalid URL: \"#{original}\". URLs must be valid according to the URL standard."}
    end
  end

  defp respond(state, message \\ nil) do
    with {:ok, _pages, state} <- refresh(state) do
      lines = Enum.map(Enum.sort(state.pages), fn {id, _target} -> page_line(id, state) end)
      fallback = if state.selection_fallback, do: fallback_message(state.selected), else: nil
      text = [message, fallback, if(lines != [], do: "## Pages"), Enum.join(lines, "\n")]
      text = text |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")
      {:ok, [%{"type" => "text", "text" => text}], state}
    end
  end

  defp page_line(id, state) do
    page = state.page_info[id]
    url = page["url"]
    without_scheme = String.replace(url, ~r/^https?:\/\//, "")

    title =
      if page["title"] in [url, without_scheme, String.trim_trailing(without_scheme, "/")],
        do: "",
        else: page["title"]

    title = if String.length(title) > 50, do: String.slice(title, 0, 49) <> "…", else: title
    label = if title == "", do: page["url"], else: "#{title} (#{page["url"]})"
    selected = if state.selected == id, do: " [selected]", else: ""
    context = Map.get(state, :page_contexts, %{})[id]
    isolated = if context, do: " isolatedContext=#{context}", else: ""
    "#{id}: #{label}#{selected}#{isolated}"
  end

  defp fallback_message(nil), do: "Note: the previously selected page was closed."

  defp fallback_message(id),
    do: "Note: the previously selected page was closed. Page #{id} is now selected."

  defp first_id(pages), do: pages |> Map.keys() |> Enum.min(fn -> nil end)

  defp by_id(id, state) do
    case state.pages[id] do
      nil -> {:error, "No page found", state}
      target -> {:ok, target, state}
    end
  end

  defp focus(target, true, state),
    do: page_command(state, target, "Page.bringToFront", %{})

  defp focus(_target, _bring_to_front, _state), do: {:ok, %{}}

  defp context(nil, state), do: {:ok, nil, state}

  defp context(name, state) do
    case state.contexts[name] do
      nil ->
        case Client.command(state.port, :browser, "Target.createBrowserContext", %{}) do
          {:ok, %{"browserContextId" => id}} ->
            {:ok, id, %{state | contexts: Map.put(state.contexts, name, id)}}

          {:error, message} ->
            {:error, message, state}

          _ ->
            {:error, "Chrome did not return a browser context", state}
        end

      id ->
        {:ok, id, state}
    end
  end

  defp finish_new_page(target, args, state) do
    previous = state.selected

    case refresh_target(target, state, System.monotonic_time(:millisecond) + 3_000) do
      {:ok, _pages, state} ->
        {id, _target} = Enum.find(state.pages, fn {_id, value} -> value == target end)
        contexts = Map.put(Map.get(state, :page_contexts, %{}), id, args["isolatedContext"])
        state = Map.merge(state, %{selected: id, page_contexts: contexts, snapshots: %{}})

        result =
          with {:ok, _pid, state} <- Diagnostics.ensure(target, state) do
            {navigate(target, "url", args, state), state}
          else
            {:error, message, state} -> {{:error, message}, state}
          end

        case result do
          {{:ok, _url}, state} ->
            respond(state)

          {{:error, message}, state} ->
            Client.command(state.port, :browser, "Target.closeTarget", %{"targetId" => target})
            restored = %{state | selected: previous}

            case refresh(restored) do
              {:ok, _pages, state} -> {:error, message, state}
              {:error, _cleanup_error, _state} -> {:error, message, restored}
            end
        end

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  defp refresh_target(target, state, deadline) do
    with {:ok, pages, state} <- refresh(state) do
      cond do
        target in Map.values(state.pages) ->
          {:ok, pages, state}

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, "Chrome page was not found", state}

        true ->
          Process.sleep(50)
          refresh_target(target, state, deadline)
      end
    end
  end

  defp restricted_page?(%{"url" => url}) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}}
      when scheme in ["chrome-extension", "chrome-untrusted", "devtools"] ->
        true

      {:ok, %URI{scheme: "chrome", host: host}} ->
        host not in ["newtab", "new-tab-page", "inspect"]

      _ ->
        false
    end
  end

  defp navigation_args(%{"initScript" => _}), do: {:error, "JavaScript evaluation is disabled."}

  defp navigation_args(args) do
    cond do
      args["type"] not in [nil, "url", "back", "forward", "reload"] ->
        {:error, "Invalid navigation type"}

      args["type"] == nil and args["url"] == nil ->
        {:error, "Either URL or a type is required."}

      args["type"] in [nil, "url"] ->
        validate_url(args["url"])

      args["url"] != nil ->
        validate_url(args["url"])

      args["type"] in ["back", "forward", "reload"] ->
        :ok

      true ->
        {:error, "Invalid navigation type"}
    end
  end

  defp navigate(target, type, args, state) do
    timeout_ms = timeout(args)
    observer = state.observers[target]
    Observer.before_unload(observer, args["handleBeforeUnload"] || "accept")
    task = Task.async(fn -> perform_navigation(target, type, args, timeout_ms, state) end)

    try do
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, "Navigation timeout of #{timeout_ms} ms exceeded"}
      end
    after
      Observer.before_unload(observer, nil)
    end
  end

  defp perform_navigation(target, type, args, timeout_ms, state) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, result} <- navigate_command(target, type, args, state),
         :ok <- navigation_result(result),
         :ok <- wait_for_load(target, result["loaderId"], deadline, timeout_ms, state),
         {:ok, %{"frameTree" => %{"frame" => frame}}} <-
           page_command(state, target, "Page.getFrameTree", %{}) do
      {:ok, frame["url"]}
    end
  end

  defp navigate_command(target, "url", args, state),
    do: page_command(state, target, "Page.navigate", %{"url" => args["url"]})

  defp navigate_command(target, "reload", args, state),
    do:
      page_command(state, target, "Page.reload", %{
        "ignoreCache" => args["ignoreCache"] == true
      })

  defp navigate_command(target, type, _args, state) do
    with {:ok, %{"currentIndex" => index, "entries" => entries}} <-
           page_command(state, target, "Page.getNavigationHistory", %{}) do
      offset = if type == "back", do: -1, else: 1

      case Enum.at(entries, index + offset) do
        %{"id" => id, "url" => url} when index + offset >= 0 ->
          with :ok <- validate_url(url) do
            page_command(state, target, "Page.navigateToHistoryEntry", %{"entryId" => id})
          end

        _ ->
          {:ok, %{}}
      end
    end
  end

  defp page_command(state, target, method, params) do
    case Map.get(state, :observers, %{})[target] do
      pid when is_pid(pid) -> Observer.command(pid, method, params)
      _ -> Client.command(state.port, target, method, params)
    end
  end

  defp navigation_result(%{"errorText" => message}), do: {:error, message}
  defp navigation_result(_result), do: :ok

  defp wait_for_load(target, loader, deadline, timeout_ms, state) do
    with true <- System.monotonic_time(:millisecond) < deadline,
         {:ok, %{"frameTree" => %{"frame" => frame}}} <-
           page_command(state, target, "Page.getFrameTree", %{}),
         {:ok, %{"result" => %{"value" => readiness}}} <-
           page_command(state, target, "Runtime.evaluate", %{
             "expression" => "document.readyState",
             "returnByValue" => true
           }) do
      if (loader == nil or loader == frame["loaderId"]) and readiness == "complete" do
        :ok
      else
        Process.sleep(50)
        wait_for_load(target, loader, deadline, timeout_ms, state)
      end
    else
      false -> {:error, "Navigation timeout of #{timeout_ms} ms exceeded"}
      {:error, message} -> {:error, message}
      _ -> {:error, "Unable to determine page load state"}
    end
  end

  defp timeout(%{"timeout" => value}) when is_integer(value) and value > 0, do: value
  defp timeout(_args), do: @default_timeout

  defp navigation_success("url", url), do: "Successfully navigated to #{url}."
  defp navigation_success("back", url), do: "Successfully navigated back to #{url}."
  defp navigation_success("forward", url), do: "Successfully navigated forward to #{url}."
  defp navigation_success("reload", _url), do: "Successfully reloaded the page."
  defp navigation_failure("url", error), do: "Unable to navigate in the selected page: #{error}."

  defp navigation_failure("back", error),
    do: "Unable to navigate back in the selected page: #{error}."

  defp navigation_failure("forward", error),
    do: "Unable to navigate forward in the selected page: #{error}."

  defp navigation_failure("reload", error), do: "Unable to reload the selected page: #{error}."

  defp dimensions(%{"width" => width, "height" => height})
       when is_integer(width) and width > 0 and is_integer(height) and height > 0,
       do: :ok

  defp dimensions(_args), do: {:error, "Page width and height must be positive integers"}

  defp normalize_window(window_id, %{"windowState" => state}, config) when state != "normal" do
    params = %{"windowId" => window_id, "bounds" => %{"windowState" => "normal"}}

    with {:ok, _} <- Client.command(config.port, :browser, "Browser.setWindowBounds", params) do
      if state == "fullscreen",
        do: Client.command(config.port, :browser, "Browser.setWindowBounds", params),
        else: {:ok, %{}}
    end
  end

  defp normalize_window(_window_id, _bounds, _state), do: {:ok, %{}}
end
