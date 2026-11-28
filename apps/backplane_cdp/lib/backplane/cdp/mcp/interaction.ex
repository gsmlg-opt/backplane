defmodule Backplane.CDP.MCP.Interaction do
  @moduledoc "Native Chrome DevTools MCP snapshots, screenshots, and element interactions."

  import Bitwise

  alias Backplane.CDP.Client
  alias Backplane.CDP.MCP.{Artifacts, Pages, Snapshot}

  @options %{
    "take_snapshot" => ~w(pageId verbose filePath),
    "take_screenshot" => ~w(pageId format quality uid fullPage omitBackground filePath),
    "click" => ~w(pageId uid dblClick includeSnapshot),
    "hover" => ~w(pageId uid includeSnapshot),
    "fill" => ~w(pageId uid value includeSnapshot),
    "fill_form" => ~w(pageId elements includeSnapshot),
    "drag" => ~w(pageId from_uid to_uid includeSnapshot),
    "type_text" => ~w(pageId text submitKey),
    "press_key" => ~w(pageId key includeSnapshot),
    "wait_for" => ~w(pageId text timeout visible)
  }

  @point_function """
  function() {
    if (!this.isConnected) throw new Error('Element is detached');
    this.scrollIntoView({block:'center', inline:'center'});
    const box = this.getBoundingClientRect();
    const style = getComputedStyle(this);
    if (!box.width || !box.height || style.visibility === 'hidden' || style.display === 'none')
      throw new Error('Element is not visible');
    if (this.disabled) throw new Error('Element is disabled');
    const x = Math.max(0, Math.min(innerWidth - 1, box.x + box.width / 2));
    const y = Math.max(0, Math.min(innerHeight - 1, box.y + box.height / 2));
    const hit = this.ownerDocument.elementFromPoint(x, y);
    if (!hit || !(this === hit || this.contains(hit))) throw new Error('Element is obscured');
    return {x, y};
  }
  """

  @fill_function """
  function(value) {
    if (!this.isConnected) throw new Error('Element is detached');
    if (this.disabled || this.readOnly) throw new Error('Element is not editable');
    if (this instanceof HTMLInputElement && this.type === 'file')
      throw new Error('File upload is not supported');
    this.focus();
    const role = this.getAttribute('role');
    if ((this instanceof HTMLInputElement && ['checkbox','radio'].includes(this.type)) ||
        ['checkbox','radio','switch'].includes(role)) {
      if (!['true','false'].includes(value)) throw new Error('Toggles require true or false');
      if ((this.type === 'radio' || role === 'radio') && value !== 'true')
        throw new Error('Radio buttons require true');
      const checked = this instanceof HTMLInputElement ? this.checked : this.getAttribute('aria-checked') === 'true';
      if (checked !== (value === 'true')) this.click();
      return true;
    }
    if (this instanceof HTMLSelectElement) {
      const option = Array.from(this.options).find(option => option.textContent === value);
      if (!option || option.disabled || option.parentElement.disabled) throw new Error('Select option was not found or is disabled');
      this.value = option.value;
    } else if (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement) {
      const prototype = this instanceof HTMLInputElement ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
      Object.getOwnPropertyDescriptor(prototype, 'value').set.call(this, value);
    } else if (this.isContentEditable) {
      this.textContent = value;
    } else {
      throw new Error('Element is not an input, textarea, select, or contenteditable');
    }
    this.dispatchEvent(new Event('input', {bubbles:true}));
    this.dispatchEvent(new Event('change', {bubbles:true}));
    return true;
  }
  """

  @wait_function """
  function(texts, visible) {
    const shown = el => {
      if (!el || !el.isConnected) return false;
      const style = getComputedStyle(el);
      return style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse' && el.getClientRects().length > 0;
    };
    const walker = this.createTreeWalker(this.documentElement, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (['SCRIPT','STYLE','NOSCRIPT'].includes(node.parentElement?.tagName)) continue;
      if ((!visible || shown(node.parentElement)) && texts.some(text => node.nodeValue.includes(text))) return true;
    }
    return false;
  }
  """

  @named_keys %{
    "Enter" => {"Enter", "Enter", 13, "\r"},
    "NumpadEnter" => {"Enter", "NumpadEnter", 13, "\r"},
    "Tab" => {"Tab", "Tab", 9, nil},
    "Escape" => {"Escape", "Escape", 27, nil},
    "Backspace" => {"Backspace", "Backspace", 8, nil},
    "Delete" => {"Delete", "Delete", 46, nil},
    "Insert" => {"Insert", "Insert", 45, nil},
    "ArrowLeft" => {"ArrowLeft", "ArrowLeft", 37, nil},
    "ArrowUp" => {"ArrowUp", "ArrowUp", 38, nil},
    "ArrowRight" => {"ArrowRight", "ArrowRight", 39, nil},
    "ArrowDown" => {"ArrowDown", "ArrowDown", 40, nil},
    "Home" => {"Home", "Home", 36, nil},
    "End" => {"End", "End", 35, nil},
    "PageUp" => {"PageUp", "PageUp", 33, nil},
    "PageDown" => {"PageDown", "PageDown", 34, nil},
    "Space" => {" ", "Space", 32, " "},
    " " => {" ", "Space", 32, " "},
    "Control" => {"Control", "ControlLeft", 17, nil},
    "Shift" => {"Shift", "ShiftLeft", 16, nil},
    "Alt" => {"Alt", "AltLeft", 18, nil},
    "Meta" => {"Meta", "MetaLeft", 91, nil}
  }
  @modifiers %{"Alt" => 1, "Control" => 2, "Meta" => 4, "Shift" => 8}
  @punctuation %{
    ";" => {"Semicolon", 186},
    ":" => {"Semicolon", 186},
    "=" => {"Equal", 187},
    "+" => {"Equal", 187},
    "," => {"Comma", 188},
    "<" => {"Comma", 188},
    "-" => {"Minus", 189},
    "_" => {"Minus", 189},
    "." => {"Period", 190},
    ">" => {"Period", 190},
    "/" => {"Slash", 191},
    "?" => {"Slash", 191},
    "`" => {"Backquote", 192},
    "~" => {"Backquote", 192},
    "[" => {"BracketLeft", 219},
    "{" => {"BracketLeft", 219},
    "\\" => {"Backslash", 220},
    "|" => {"Backslash", 220},
    "]" => {"BracketRight", 221},
    "}" => {"BracketRight", 221},
    "'" => {"Quote", 222},
    "\"" => {"Quote", 222}
  }

  def call(name, args, state) when is_map(args) do
    with :ok <- validate(name, args),
         {:ok, target, state} <- Pages.selected(args, state) do
      dispatch(name, args, target, state)
    else
      {:error, message, state} -> {:error, message, state}
      {:error, message} -> {:error, message, state}
    end
  end

  def call(_name, _args, state), do: {:error, "Invalid interaction arguments", state}

  defp dispatch("take_snapshot", args, target, state) do
    Client.with_connection(state.port, target, fn connection ->
      with {:ok, text, state} <-
             Snapshot.capture(connection, target, state, args["verbose"] == true) do
        case args["filePath"] do
          nil ->
            {:ok, blocks(text), state}

          path ->
            save(
              path,
              String.replace_prefix(text, "## Latest page snapshot\n", ""),
              "Saved snapshot to",
              state
            )
        end
      end
    end)
    |> normalize(state)
  end

  defp dispatch("take_screenshot", args, target, state) do
    Client.with_connection(state.port, target, fn connection ->
      screenshot(connection, args, target, state)
    end)
    |> normalize(state)
  end

  defp dispatch("wait_for", args, target, state) do
    deadline = System.monotonic_time(:millisecond) + timeout(args)
    wait_for(args, target, state, deadline)
  end

  defp dispatch(name, args, target, state) do
    Client.with_connection(state.port, target, fn connection ->
      with {:ok, message} <- perform(connection, name, args, target, state) do
        if args["includeSnapshot"] == true do
          with {:ok, snapshot, state} <- Snapshot.capture(connection, target, state) do
            {:ok, blocks(message <> "\n" <> snapshot), state}
          end
        else
          {:ok, blocks(message), state}
        end
      end
    end)
    |> normalize(state)
  end

  defp perform(connection, "click", args, target, state) do
    with {:ok, object} <- Snapshot.resolve(connection, target, state, args["uid"]),
         {:ok, selected} <-
           invoke(connection, object, option_click_function(), [args["dblClick"] == true]),
         :ok <- click_unless_selected(connection, object, selected, args["dblClick"] == true) do
      {:ok,
       if(args["dblClick"],
         do: "Successfully double clicked on the element",
         else: "Successfully clicked on the element"
       )}
    end
  end

  defp perform(connection, "hover", args, target, state) do
    with {:ok, object} <- Snapshot.resolve(connection, target, state, args["uid"]),
         {:ok, %{"x" => x, "y" => y}} <- invoke(connection, object, @point_function, []),
         {:ok, _} <- mouse(connection, "mouseMoved", x, y) do
      {:ok, "Successfully hovered over the element"}
    end
  end

  defp perform(connection, "fill", args, target, state) do
    with :ok <- fill(connection, args, target, state),
         do: {:ok, "Successfully filled out the element"}
  end

  defp perform(connection, "fill_form", args, target, state) do
    result =
      Enum.reduce_while(args["elements"], :ok, fn element, :ok ->
        case fill(connection, element, target, state) do
          :ok ->
            {:cont, :ok}

          {:error, message} ->
            {:halt, {:error, "Failed to fill uid #{element["uid"]}: #{message}"}}
        end
      end)

    with :ok <- result, do: {:ok, "Successfully filled out the form"}
  end

  defp perform(connection, "type_text", args, _target, _state) do
    with {:ok, _} <-
           Client.send_command(connection, "Input.insertText", %{"text" => args["text"]}),
         :ok <- submit(connection, args["submitKey"]) do
      key = if args["submitKey"] in [nil, ""], do: "", else: " + #{args["submitKey"]}"
      {:ok, "Typed text \"#{args["text"]}#{key}\""}
    end
  end

  defp perform(connection, "press_key", args, _target, _state) do
    with :ok <- press(connection, args["key"]),
         do: {:ok, "Successfully pressed key: #{args["key"]}"}
  end

  defp perform(connection, "drag", args, target, state) do
    with {:ok, from} <- Snapshot.resolve(connection, target, state, args["from_uid"]),
         {:ok, to} <- Snapshot.resolve(connection, target, state, args["to_uid"]),
         {:ok, %{"x" => x, "y" => y}} <- invoke(connection, from, @point_function, []),
         {:ok, _} <-
           Client.send_command(connection, "Input.setInterceptDrags", %{"enabled" => true}) do
      try do
        with {:ok, _} <- mouse(connection, "mouseMoved", x, y),
             {:ok, _} <- mouse(connection, "mousePressed", x, y, 1),
             {:ok, %{"x" => to_x, "y" => to_y}} <- invoke(connection, to, @point_function, []),
             {:ok, _} <-
               Client.send_command(connection, "Input.dispatchMouseEvent", %{
                 "type" => "mouseMoved",
                 "x" => to_x,
                 "y" => to_y,
                 "button" => "left",
                 "buttons" => 1
               }),
             {:ok, %{"data" => data}} <-
               Client.wait_for_event(connection, "Input.dragIntercepted", 3_000),
             :ok <- dispatch_drag(connection, to_x, to_y, data) do
          {:ok, "Successfully dragged an element"}
        end
      after
        mouse(connection, "mouseReleased", x, y, 1)
        Client.send_command(connection, "Input.setInterceptDrags", %{"enabled" => false})
      end
    end
  end

  defp dispatch_drag(connection, x, y, data) do
    Enum.reduce_while(~w(dragEnter dragOver drop), :ok, fn type, :ok ->
      case Client.send_command(connection, "Input.dispatchDragEvent", %{
             "type" => type,
             "x" => x,
             "y" => y,
             "data" => data
           }) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp fill(connection, args, target, state) do
    with {:ok, object} <- Snapshot.resolve(connection, target, state, args["uid"]),
         {:ok, true} <- invoke(connection, object, @fill_function, [args["value"]]),
         do: :ok
  end

  defp click_unless_selected(_connection, _object, true, _double), do: :ok

  defp click_unless_selected(connection, object, false, double) do
    with {:ok, %{"x" => x, "y" => y}} <- invoke(connection, object, @point_function, []) do
      count = if double, do: 2, else: 1

      Enum.reduce_while(1..count, :ok, fn click_count, :ok ->
        with {:ok, _} <- mouse(connection, "mousePressed", x, y, click_count),
             {:ok, _} <- mouse(connection, "mouseReleased", x, y, click_count) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp mouse(connection, type, x, y, count \\ 0) do
    params = %{"type" => type, "x" => x, "y" => y}

    params =
      if count > 0,
        do: Map.merge(params, %{"button" => "left", "clickCount" => count}),
        else: params

    Client.send_command(connection, "Input.dispatchMouseEvent", params)
  end

  defp submit(_connection, key) when key in [nil, ""], do: :ok
  defp submit(connection, key), do: press(connection, key)

  defp press(connection, combination) do
    with {:ok, keys} <- parse_keys(combination) do
      {modifiers, [key]} = Enum.split(keys, -1)

      held_modifiers(connection, modifiers, 0, fn flags ->
        try do
          with {:ok, _} <- key_event(connection, "keyDown", key, flags), do: :ok
        after
          key_event(connection, "keyUp", key, flags)
        end
      end)
    end
  end

  defp held_modifiers(_connection, [], flags, operation), do: operation.(flags)

  defp held_modifiers(connection, [modifier | rest], flags, operation) do
    updated = flags ||| Map.fetch!(@modifiers, modifier)

    with {:ok, _} <- key_event(connection, "rawKeyDown", modifier, updated) do
      try do
        held_modifiers(connection, rest, updated, operation)
      after
        key_event(connection, "keyUp", modifier, flags)
      end
    end
  end

  defp key_event(connection, type, key, modifiers) do
    {:ok, {key, code, keycode, text}} = key_definition(key)

    params = %{
      "type" => type,
      "key" => key,
      "code" => code,
      "windowsVirtualKeyCode" => keycode,
      "modifiers" => modifiers
    }

    params =
      if (type == "keyDown" and text) && (modifiers &&& 6) == 0,
        do: Map.merge(params, %{"text" => text, "unmodifiedText" => text}),
        else: params

    Client.send_command(connection, "Input.dispatchKeyEvent", params)
  end

  @doc false
  def parse_keys(combination) when is_binary(combination) do
    {parts, current} =
      Enum.reduce(String.graphemes(combination), {[], ""}, fn
        "+", {parts, current} when current != "" -> {parts ++ [current], ""}
        char, {parts, current} -> {parts, current <> char}
      end)

    keys = if current == "", do: parts, else: parts ++ [current]
    modifiers = Enum.drop(keys, -1)

    if keys != [] and length(Enum.uniq(keys)) == length(keys) and
         Enum.all?(modifiers, &Map.has_key?(@modifiers, &1)) and
         Enum.all?(keys, &match?({:ok, _}, key_definition(&1))) do
      {:ok, keys}
    else
      {:error, "Unsupported key or key combination: #{combination}"}
    end
  end

  def parse_keys(_combination), do: {:error, "A key is required"}

  defp key_definition(key) do
    cond do
      Map.has_key?(@named_keys, key) ->
        {:ok, @named_keys[key]}

      Regex.match?(~r/\A[A-Za-z]\z/, key) ->
        {:ok, {key, "Key" <> String.upcase(key), :binary.first(String.upcase(key)), key}}

      Regex.match?(~r/\A[0-9]\z/, key) ->
        {:ok, {key, "Digit" <> key, :binary.first(key), key}}

      Map.has_key?(@punctuation, key) ->
        {code, keycode} = @punctuation[key]
        {:ok, {key, code, keycode, key}}

      Regex.match?(~r/\AF(?:[1-9]|1[0-9]|2[0-4])\z/, key) ->
        {:ok, {key, key, 111 + String.to_integer(String.trim_leading(key, "F")), nil}}

      true ->
        {:error, "Unsupported key"}
    end
  end

  defp screenshot(connection, args, target, state) do
    format = args["format"] || "png"

    with {:ok, clip} <- screenshot_clip(connection, args, target, state),
         {:ok, result} <- capture_image(connection, args, format, clip),
         %{"data" => data} when is_binary(data) <- result,
         {:ok, bytes} <- Base.decode64(data) do
      description =
        cond do
          args["uid"] -> "Took a screenshot of node with uid \"#{args["uid"]}\"."
          args["fullPage"] -> "Took a screenshot of the full current page."
          true -> "Took a screenshot of the current page's viewport."
        end

      case args["filePath"] do
        nil ->
          {:ok,
           blocks(description) ++
             [%{"type" => "image", "data" => data, "mimeType" => "image/#{format}"}], state}

        path ->
          save(path, bytes, description <> "\nSaved screenshot to", state)
      end
    else
      {:error, message} when is_binary(message) -> {:error, message, state}
      _ -> {:error, "Chrome did not return valid screenshot data", state}
    end
  end

  defp screenshot_clip(connection, %{"uid" => uid}, target, state) do
    with {:ok, object} <- Snapshot.resolve(connection, target, state, uid),
         {:ok, clip} <- invoke(connection, object, screenshot_box_function(), []) do
      {:ok, Map.put(clip, "scale", 1)}
    end
  end

  defp screenshot_clip(connection, %{"fullPage" => true}, _target, _state) do
    with {:ok, %{"cssContentSize" => size}} <-
           Client.send_command(connection, "Page.getLayoutMetrics", %{}) do
      {:ok, Map.put(size, "scale", 1)}
    end
  end

  defp screenshot_clip(_connection, _args, _target, _state), do: {:ok, nil}

  defp capture_image(connection, args, format, clip) do
    params = %{
      "format" => format,
      "captureBeyondViewport" => args["fullPage"] == true or args["uid"] != nil
    }

    params = if clip, do: Map.put(params, "clip", clip), else: params

    params =
      if format != "png" and args["quality"] != nil,
        do: Map.put(params, "quality", round(args["quality"])),
        else: params

    transparent = args["omitBackground"] == true and format != "jpeg"

    if transparent do
      with {:ok, _} <-
             Client.send_command(connection, "Emulation.setDefaultBackgroundColorOverride", %{
               "color" => %{"r" => 0, "g" => 0, "b" => 0, "a" => 0}
             }) do
        try do
          Client.send_command(connection, "Page.captureScreenshot", params)
        after
          Client.send_command(connection, "Emulation.setDefaultBackgroundColorOverride", %{})
        end
      end
    else
      Client.send_command(connection, "Page.captureScreenshot", params)
    end
  end

  defp wait_for(args, target, state, deadline) do
    result =
      Client.with_connection(state.port, target, fn connection ->
        with {:ok, %{"result" => %{"objectId" => document}}} <-
               Client.send_command(connection, "Runtime.evaluate", %{"expression" => "document"}),
             {:ok, matched} <-
               invoke(connection, document, @wait_function, [
                 args["text"],
                 args["visible"] == true
               ]) do
          if matched, do: {:ok, true}, else: accessible_match(connection, args, target, state)
        end
      end)

    case result do
      {:ok, true} ->
        Client.with_connection(state.port, target, fn connection ->
          with {:ok, snapshot, state} <- Snapshot.capture(connection, target, state) do
            {:ok,
             blocks(
               "Element matching one of #{Formata.JSON.encode!(args["text"])} found.\n" <>
                 snapshot
             ), state}
          end
        end)
        |> normalize(state)

      {:ok, false} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, "Waiting for text timed out. Text matching is case-sensitive.", state}
        else
          Process.sleep(100)
          wait_for(args, target, state, deadline)
        end

      {:error, message} ->
        {:error, message, state}
    end
  end

  defp accessible_match(connection, args, _target, _state) do
    with {:ok, %{"nodes" => nodes}} <-
           Client.send_command(connection, "Accessibility.getFullAXTree", %{}) do
      matches =
        Enum.filter(
          nodes,
          &(get_in(&1, ["name", "value"]) in args["text"] and &1["ignored"] != true)
        )

      if args["visible"] == true do
        Enum.reduce_while(matches, {:ok, false}, fn node, _acc ->
          with {:ok, %{"object" => %{"objectId" => object}}} <-
                 Client.send_command(connection, "DOM.resolveNode", %{
                   "backendNodeId" => node["backendDOMNodeId"]
                 }),
               {:ok, visible} <- invoke(connection, object, visible_function(), []) do
            if visible, do: {:halt, {:ok, true}}, else: {:cont, {:ok, false}}
          else
            {:error, _} = error -> {:halt, error}
            _ -> {:halt, {:error, "Chrome did not return an accessible element"}}
          end
        end)
      else
        {:ok, matches != []}
      end
    end
  end

  defp invoke(connection, object, function, values) do
    arguments = Enum.map(values, &%{"value" => &1})
    invoke_arguments(connection, object, function, arguments)
  end

  defp invoke_arguments(connection, object, function, arguments) do
    case Client.send_command(connection, "Runtime.callFunctionOn", %{
           "objectId" => object,
           "functionDeclaration" => function,
           "arguments" => arguments,
           "returnByValue" => true
         }) do
      {:ok, %{"exceptionDetails" => details}} ->
        {:error,
         get_in(details, ["exception", "description"]) || details["text"] ||
           "Element interaction failed"}

      {:ok, %{"result" => %{"value" => value}}} ->
        {:ok, value}

      {:ok, _} ->
        {:error, "Chrome did not return an interaction result"}

      error ->
        error
    end
  end

  defp save(path, bytes, prefix, state) do
    case Artifacts.write(path, bytes) do
      {:ok, absolute} -> {:ok, blocks("#{prefix} #{absolute}."), state}
      {:error, message} -> {:error, message, state}
    end
  end

  defp blocks(text), do: [%{"type" => "text", "text" => text}]
  defp normalize({:error, message}, state), do: {:error, message, state}
  defp normalize(result, _state), do: result

  defp validate(name, args) do
    allowed = @options[name]
    unknown = if allowed, do: Map.keys(args) -- allowed, else: []

    cond do
      allowed == nil ->
        {:error, "Unsupported interaction tool: #{name}"}

      unknown != [] ->
        {:error, "Unsupported options: #{Enum.join(unknown, ", ")}"}

      Enum.any?(
        ~w(verbose fullPage omitBackground dblClick includeSnapshot visible),
        &(Map.has_key?(args, &1) and not is_boolean(args[&1]))
      ) ->
        {:error, "Interaction flags must be boolean"}

      Enum.any?(
        ~w(uid from_uid to_uid value filePath submitKey key),
        &(Map.has_key?(args, &1) and not is_binary(args[&1]))
      ) ->
        {:error, "Interaction string arguments must be strings"}

      name in ~w(click hover fill) and not is_binary(args["uid"]) ->
        {:error, "An element uid is required"}

      name == "fill" and not is_binary(args["value"]) ->
        {:error, "A fill value is required"}

      name == "fill_form" and not valid_elements?(args["elements"]) ->
        {:error, "elements must contain uid and value strings"}

      name == "drag" and not (is_binary(args["from_uid"]) and is_binary(args["to_uid"])) ->
        {:error, "from_uid and to_uid are required"}

      name == "type_text" and not is_binary(args["text"]) ->
        {:error, "Text is required"}

      name == "press_key" ->
        validate_keys(args["key"])

      name == "type_text" and args["submitKey"] not in [nil, ""] ->
        validate_submit(args["submitKey"])

      name == "take_screenshot" ->
        validate_screenshot(args)

      name == "wait_for" ->
        validate_wait(args)

      true ->
        :ok
    end
  end

  defp valid_elements?(elements) when is_list(elements),
    do:
      Enum.all?(
        elements,
        &(is_map(&1) and is_binary(&1["uid"]) and is_binary(&1["value"]) and
            Map.keys(&1) -- ~w(uid value) == [])
      )

  defp valid_elements?(_elements), do: false

  defp validate_keys(key) do
    case parse_keys(key) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp validate_submit(key) do
    case parse_keys(key) do
      {:ok, [_single]} -> :ok
      _ -> {:error, "submitKey must be a single supported key"}
    end
  end

  defp validate_screenshot(args) do
    cond do
      (args["format"] || "png") not in ~w(png jpeg webp) ->
        {:error, "Unsupported screenshot format"}

      args["quality"] != nil and
          not (is_number(args["quality"]) and args["quality"] >= 0 and args["quality"] <= 100) ->
        {:error, "Screenshot quality must be between 0 and 100"}

      args["uid"] != nil and args["fullPage"] == true ->
        {:error, "Providing both \"uid\" and \"fullPage\" is not allowed."}

      true ->
        :ok
    end
  end

  defp validate_wait(args) do
    cond do
      not (is_list(args["text"]) and args["text"] != [] and Enum.all?(args["text"], &is_binary/1)) ->
        {:error, "text must be a non-empty list of strings"}

      args["timeout"] != nil and
          not (is_integer(args["timeout"]) and args["timeout"] in 0..120_000) ->
        {:error, "Native wait timeout must be between 0 and 120000 milliseconds"}

      true ->
        :ok
    end
  end

  defp timeout(args), do: if(args["timeout"] in [nil, 0], do: 30_000, else: args["timeout"])

  defp option_click_function do
    """
    function(doubleClick) {
      if (!(this instanceof HTMLOptionElement)) return false;
      if (doubleClick) throw new Error('Double-clicking select options is unsupported');
      const select = this.closest('select');
      if (!select || select.multiple || select.disabled || this.disabled || this.parentElement.disabled)
        throw new Error('The select option is not interactive');
      select.value = this.value;
      select.dispatchEvent(new Event('input', {bubbles:true}));
      select.dispatchEvent(new Event('change', {bubbles:true}));
      return true;
    }
    """
  end

  defp screenshot_box_function do
    """
    function() {
      if (!this.isConnected) throw new Error('Element is detached');
      const box = this.getBoundingClientRect();
      if (!box.width || !box.height) throw new Error('Element has no screenshot area');
      return {x:box.x + scrollX, y:box.y + scrollY, width:box.width, height:box.height};
    }
    """
  end

  defp visible_function do
    """
    function() {
      const style = getComputedStyle(this);
      return this.isConnected && style.display !== 'none' && style.visibility !== 'hidden' &&
        style.visibility !== 'collapse' && this.getClientRects().length > 0;
    }
    """
  end
end
