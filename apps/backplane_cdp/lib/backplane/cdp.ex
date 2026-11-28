defmodule Backplane.CDP do
  @moduledoc """
  Standalone CLI operations using Chrome target IDs and the configured loopback port.
  The host agent exposes the session-based tool catalog in `Backplane.CDP.MCP`.
  """

  alias Backplane.CDP.{Client, Config}

  @commands [
    {"list_pages", "List browser pages with their IDs, titles and URLs.", []},
    {"new_page", "Open a new page and return its page ID.", ["url"]},
    {"close_page", "Close the specified page.", ["page_id"]},
    {"navigate_page", "Start navigation to a URL in the specified page.", ["page_id", "url"]},
    {"take_snapshot", "Read the page accessibility tree.", ["page_id"]},
    {"take_screenshot", "Capture the visible page as a PNG image.", ["page_id"]},
    {"click", "Click at viewport coordinates in CSS pixels.", ["page_id", "x", "y"]},
    {"type_text", "Insert text into the focused editable element.", ["page_id", "text"]}
  ]

  @fields %{
    "page_id" => %{
      "type" => "string",
      "minLength" => 1,
      "description" => "ID from list_pages or new_page"
    },
    "url" => %{"type" => "string", "description" => "HTTP(S) URL or about:blank"},
    "x" => %{"type" => "number", "minimum" => 0},
    "y" => %{"type" => "number", "minimum" => 0},
    "text" => %{"type" => "string"}
  }

  defdelegate enabled?(), to: Config

  def tools do
    Enum.map(@commands, fn {name, description, fields} ->
      %{
        "name" => "cdp::" <> name,
        "description" => description,
        "inputSchema" => %{
          "type" => "object",
          "properties" => Map.take(@fields, fields),
          "required" => fields,
          "additionalProperties" => false
        }
      }
    end)
  end

  def call(name, args) do
    with {:ok, fields} <- fields(name),
         :ok <- validate_args(args, fields),
         {:ok, port} <- port() do
      execute(name, args, port)
    end
  end

  defp fields(name) do
    case List.keyfind(@commands, name, 0) do
      {_, _, fields} -> {:ok, fields}
      nil -> {:error, "Unknown CDP tool: #{name}"}
    end
  end

  defp validate_args(args, fields) when is_map(args) do
    cond do
      map_size(Map.drop(args, fields)) > 0 ->
        {:error, "Unexpected CDP arguments"}

      key = Enum.find(fields, &(not valid?(&1, args[&1]))) ->
        {:error, "Missing or invalid #{key}"}

      true ->
        :ok
    end
  end

  defp validate_args(_args, _fields), do: {:error, "Expected an object of CDP arguments"}

  defp valid?("url", "about:blank"), do: true

  defp valid?("url", url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp valid?("page_id", id), do: is_binary(id) and byte_size(id) > 0
  defp valid?(coord, value) when coord in ["x", "y"], do: is_number(value) and value >= 0
  defp valid?("text", text), do: is_binary(text)
  defp valid?(_, _), do: false

  defdelegate port(), to: Config

  defp execute("list_pages", _, port), do: Client.pages(port)

  defp execute("new_page", %{"url" => url}, port) do
    case Client.command(port, :browser, "Target.createTarget", %{"url" => url}) do
      {:ok, %{"targetId" => id}} when is_binary(id) -> {:ok, %{"page_id" => id}}
      {:ok, _} -> {:error, "Chrome returned no page ID"}
      error -> error
    end
  end

  defp execute("close_page", %{"page_id" => id}, port) do
    with {:ok, pages} <- Client.pages(port) do
      if Enum.any?(pages, &(&1["id"] == id)) do
        case Client.command(port, :browser, "Target.closeTarget", %{"targetId" => id}) do
          {:ok, %{"success" => true}} -> {:ok, %{"closed" => true}}
          {:ok, _} -> {:error, "Chrome did not close the page"}
          error -> error
        end
      else
        {:error, "Page not found"}
      end
    end
  end

  defp execute("navigate_page", %{"page_id" => id, "url" => url}, port) do
    case Client.command(port, id, "Page.navigate", %{"url" => url}) do
      {:ok, %{"errorText" => error}} when error != "" -> {:error, error}
      result -> result
    end
  end

  defp execute("take_snapshot", %{"page_id" => id}, port) do
    Client.command(port, id, "Accessibility.getFullAXTree", %{})
  end

  defp execute("take_screenshot", %{"page_id" => id}, port) do
    case Client.command(port, id, "Page.captureScreenshot", %{"format" => "png"}) do
      {:ok, %{"data" => data}} when is_binary(data) ->
        {:ok, %{"mimeType" => "image/png", "data" => data}}

      {:ok, _} ->
        {:error, "Chrome returned no PNG data"}

      error ->
        error
    end
  end

  defp execute("click", %{"page_id" => id, "x" => x, "y" => y}, port) do
    Client.command(port, id, "Input.synthesizeTapGesture", %{
      "x" => x,
      "y" => y,
      "gestureSourceType" => "mouse"
    })
  end

  defp execute("type_text", %{"page_id" => id, "text" => text}, port) do
    Client.command(port, id, "Input.insertText", %{"text" => text})
  end
end
