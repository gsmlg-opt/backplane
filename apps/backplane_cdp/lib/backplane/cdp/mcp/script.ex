defmodule Backplane.CDP.MCP.Script do
  @moduledoc "Read-only JavaScript inspection in an isolated world of the selected document."

  alias Backplane.CDP.{Client, Config}
  alias Backplane.CDP.MCP.{Artifacts, Observer, Pages, Snapshot}

  @max_source 131_072
  @timeout 3_000
  @stable_dom """
  new Promise(resolve => {
    let quiet;
    const done = () => { observer.disconnect(); clearTimeout(quiet); clearTimeout(limit); resolve(); };
    const changed = () => { clearTimeout(quiet); quiet = setTimeout(done, 100); };
    const observer = new MutationObserver(changed);
    const limit = setTimeout(done, 1000);
    observer.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
    changed();
  })
  """

  def call("evaluate_script", args, state) do
    with {:ok, source} <- source(args),
         :ok <- validate_args(args),
         {:ok, target, state} <- Pages.selected(args, state) do
      observer = state.observers[target]

      result =
        with :ok <- Observer.script_dialog(observer, args["dialogAction"] || "accept") do
          try do
            with {:ok, json} <-
                   Client.with_connection(state.port, target, fn conn ->
                     evaluate(conn, target, state, args, source)
                   end),
                 do: output(json, args["filePath"])
          after
            Observer.script_dialog(observer, nil)
          end
        end

      case result do
        {:ok, message} -> {:ok, [%{"type" => "text", "text" => message}], state}
        {:error, message} -> {:error, message, state}
      end
    else
      {:error, message} -> {:error, message, state}
      other -> other
    end
  end

  defp source(%{"function" => _, "sourcePath" => _}),
    do: {:error, "Specify exactly one of function or sourcePath."}

  defp source(%{"function" => source}) when byte_size(source) <= @max_source, do: {:ok, source}
  defp source(%{"function" => _}), do: {:error, "Script source exceeds 128 KiB."}

  defp source(%{"sourcePath" => path}) do
    with {:ok, root} <- Config.upload_dir(),
         path = Path.expand(path, root),
         true <- Path.dirname(path) == root,
         {:ok, %{type: :regular, size: size}} when size <= @max_source <- File.lstat(path),
         {:ok, source} <- File.open(path, [:read, :binary], &IO.binread(&1, @max_source + 1)),
         source = if(source == :eof, do: "", else: source),
         true <- is_binary(source) and byte_size(source) <= @max_source and String.valid?(source) do
      {:ok, source}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      _ ->
        {:error,
         "Choose a UTF-8 script of at most 128 KiB directly inside cdp.upload_dir (host config) or BACKPLANE_CDP_UPLOAD_DIR."}
    end
  end

  defp source(_), do: {:error, "Specify exactly one of function or sourcePath."}

  defp validate_args(%{"format" => "script", "args" => [_ | _]}),
    do: {:error, ~s(args cannot be used when format is "script".)}

  defp validate_args(_), do: :ok

  defp evaluate(conn, target, state, args, source) do
    with {:ok, context} <- world(conn),
         {:ok, bindings} <- resolve_args(conn, target, state, context, args["args"] || []),
         {:ok, result} <- run(conn, context, args["format"] || "function", source, bindings),
         {:ok, json} <- serialize(conn, context, result),
         :ok <- settle(conn, context, args["waitForStableDom"]) do
      {:ok, json}
    end
  end

  defp world(conn) do
    with {:ok, %{"frameTree" => %{"frame" => frame}}} <-
           Client.send_command(conn, "Page.getFrameTree", %{}),
         true <- is_binary(frame["url"]),
         true <-
           frame["url"] == "about:blank" or URI.parse(frame["url"]).scheme in ["http", "https"],
         {:ok, %{"executionContextId" => id}} <-
           Client.send_command(conn, "Page.createIsolatedWorld", %{
             "frameId" => frame["id"],
             "worldName" => "backplane-inspection"
           }) do
      {:ok, id}
    else
      {:error, _} = error -> error
      _ -> {:error, "Script inspection requires a web page or about:blank."}
    end
  end

  defp resolve_args(_conn, _target, _state, _context, []), do: {:ok, []}

  defp resolve_args(conn, target, state, context, uids) do
    with :ok <- Snapshot.current_document(conn, target, state) do
      Enum.reduce_while(uids, {:ok, []}, fn uid, {:ok, refs} ->
        with {:ok, backend} <- Snapshot.backend(target, state, uid),
             {:ok, %{"object" => %{"objectId" => id}}} <-
               Client.send_command(conn, "DOM.resolveNode", %{
                 "backendNodeId" => backend,
                 "executionContextId" => context
               }) do
          {:cont, {:ok, [%{"objectId" => id} | refs]}}
        else
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, {:error, "Snapshot element is no longer available. Take a new snapshot."}}
        end
      end)
    end
  end

  defp run(conn, context, "script", source, []), do: inspect_expression(conn, context, source)

  defp run(conn, context, "function", source, refs) do
    source = source |> String.trim_trailing() |> String.replace_suffix(";", "")

    if refs == [] do
      inspect_expression(conn, context, "(\n#{source}\n)()")
    else
      with_handles(conn, context, Enum.reverse(refs), fn array ->
        inspect_expression(conn, context, "(\n#{source}\n)(...#{array})")
      end)
    end
  end

  # Evaluate with V8's execution timeout, including JSON serialization that can
  # invoke getters. A separate binding per call supports overlapping sessions.
  defp with_handles(conn, context, refs, callback) do
    key = "bp_" <> Base.encode16(:crypto.strong_rand_bytes(16))

    params = %{
      "executionContextId" => context,
      "functionDeclaration" => "function(key, ...values) { globalThis[key] = values }",
      "arguments" => [%{"value" => key} | refs]
    }

    with {:ok, _} <- remote(conn, "Runtime.callFunctionOn", params) do
      try do
        callback.("globalThis.#{key}")
      after
        Client.send_command(conn, "Runtime.evaluate", %{
          "expression" => "delete globalThis.#{key}",
          "contextId" => context
        })
      end
    end
  end

  defp inspect_expression(conn, context, source) do
    remote(conn, "Runtime.evaluate", %{
      "contextId" => context,
      "expression" => source,
      "timeout" => @timeout,
      "throwOnSideEffect" => true,
      "silent" => true,
      "allowUnsafeEvalBlockedByCSP" => false
    })
  end

  # Reading the internal result of an already-settled promise keeps inspection
  # synchronous. Never run a user-supplied continuation to obtain the value.
  defp serialize(conn, context, %{"subtype" => "promise", "objectId" => id}) do
    with {:ok, %{"internalProperties" => props}} <-
           Client.send_command(conn, "Runtime.getProperties", %{
             "objectId" => id,
             "ownProperties" => true
           }) do
      props = Map.new(props, &{&1["name"], &1["value"]})

      case props do
        %{"[[PromiseState]]" => %{"value" => "fulfilled"}, "[[PromiseResult]]" => result} ->
          serialize(conn, context, result)

        %{"[[PromiseState]]" => %{"value" => "rejected"}, "[[PromiseResult]]" => reason} ->
          {:error,
           reason["description"] || "Promise rejected: #{Formata.JSON.encode!(reason["value"])}"}

        _ ->
          {:error, "Inspection requires a synchronous value or a settled promise."}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Chrome did not return the promise state."}
    end
  end

  defp serialize(_conn, _ctx, %{"type" => type}) when type in ["undefined", "symbol", "function"],
    do: {:ok, "undefined"}

  defp serialize(_conn, _ctx, %{"type" => "bigint"}),
    do: {:error, "BigInt is not JSON-serializable."}

  defp serialize(_conn, _ctx, %{"value" => value}), do: {:ok, Formata.JSON.encode!(value)}
  defp serialize(_conn, _ctx, %{"unserializableValue" => "-0"}), do: {:ok, "0"}

  defp serialize(_conn, _ctx, %{"type" => "number", "unserializableValue" => _}),
    do: {:ok, "null"}

  defp serialize(conn, context, %{"objectId" => id}) do
    with_handles(conn, context, [%{"objectId" => id}], fn values ->
      with {:ok, result} <- inspect_expression(conn, context, "JSON.stringify(#{values}[0])") do
        {:ok, result["value"] || "undefined"}
      end
    end)
  end

  defp serialize(_conn, _context, _result),
    do: {:error, "Chrome did not return a serializable value."}

  defp remote(conn, method, params) do
    case Client.send_command(conn, method, params) do
      {:ok, %{"exceptionDetails" => details}} ->
        {:error,
         get_in(details, ["exception", "description"]) || details["text"] || "Evaluation failed."}

      {:ok, %{"result" => value}} ->
        {:ok, value}

      {:error, _} = error ->
        error

      _ ->
        {:error, "Invalid Chrome evaluation response."}
    end
  end

  defp settle(_conn, _context, false), do: :ok

  defp settle(conn, context, _) do
    with {:ok, _} <-
           remote(conn, "Runtime.evaluate", %{
             "expression" => @stable_dom,
             "contextId" => context,
             "awaitPromise" => true
           }),
         do: :ok
  end

  defp output(json, nil), do: {:ok, "Script ran on page and returned:\n```json\n#{json}\n```"}

  defp output(json, path) do
    with {:ok, path} <- Artifacts.named_destination(path, ".json"),
         {:ok, _} <- Artifacts.save(path, json),
         do: {:ok, "Script ran on page. Output saved to #{path}."}
  end
end
