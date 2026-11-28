defmodule Backplane.CDP.MCP.ScriptSources do
  @moduledoc false

  alias Backplane.CDP.MCP.Observer

  @max_bytes 512 * 1024
  @max_maps 16

  # Fetch in the inspected page's origin without credentials or redirects. Reading
  # the body incrementally also bounds chunked and compressed responses.
  @read_map """
  async function(url, limit) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 2000);
    try {
      const response = await fetch(url, {mode: "same-origin", credentials: "omit",
        redirect: "error", signal: controller.signal});
      if (!response.ok || Number(response.headers.get("Content-Length")) > limit) return null;
      const reader = response.body.getReader(), decoder = new TextDecoder();
      let bytes = 0, text = "";
      while (true) {
        const {value, done} = await reader.read();
        if (done) return text + decoder.decode();
        bytes += value.length;
        if (bytes > limit) return null;
        text += decoder.decode(value, {stream: true});
      }
    } catch { return null; } finally { clearTimeout(timeout); controller.abort(); }
  }
  """

  def maps(pid, scripts) do
    sources =
      scripts
      |> Enum.filter(fn {_url, ref} -> is_binary(ref) and ref != "" end)
      |> Enum.take(@max_maps)

    if sources == [] do
      []
    else
      context = context(pid)

      Enum.flat_map(sources, fn {script, ref} ->
        case read(pid, context, script, ref) do
          {:ok, base, json} ->
            case Formata.JSON.decode(json) do
              {:ok, %{"version" => 3} = map} -> [{script, base, map}]
              _ -> []
            end

          _ ->
            []
        end
      end)
    end
  end

  defp context(pid) do
    with {:ok, %{"frameTree" => %{"frame" => %{"id" => frame}}}} <-
           Observer.command(pid, "Page.getFrameTree", %{}),
         {:ok, %{"executionContextId" => id}} <-
           Observer.command(pid, "Page.createIsolatedWorld", %{
             "frameId" => frame,
             "worldName" => "backplane-source-maps"
           }) do
      id
    else
      _ -> nil
    end
  end

  defp read(_pid, _ctx, script, "data:" <> data) do
    with [header, payload] <- String.split(data, ",", parts: 2),
         {:ok, bytes} <- decode_data(header, payload),
         true <- byte_size(bytes) <= @max_bytes do
      {:ok, script, bytes}
    else
      _ -> :unavailable
    end
  end

  defp read(pid, ctx, script, ref) when is_integer(ctx) do
    with {:ok, relative} <- URI.new(ref),
         %URI{scheme: scheme, userinfo: nil} = uri when scheme in ["https", "http"] <-
           URI.merge(script, relative),
         url = URI.to_string(uri),
         {:ok, %{"result" => %{"value" => json}}} when is_binary(json) <-
           Observer.command(
             pid,
             "Runtime.callFunctionOn",
             %{
               "executionContextId" => ctx,
               "functionDeclaration" => @read_map,
               "arguments" => [%{"value" => url}, %{"value" => @max_bytes}],
               "returnByValue" => true,
               "awaitPromise" => true
             },
             3500
           ) do
      {:ok, url, json}
    else
      _ -> :unavailable
    end
  end

  defp read(_pid, _ctx, _script, _ref), do: :unavailable

  defp decode_data(header, data) do
    if String.ends_with?(header, ";base64"),
      do: Base.decode64(data),
      else: {:ok, URI.decode(data)}
  end
end
