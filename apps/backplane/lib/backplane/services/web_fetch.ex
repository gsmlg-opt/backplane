defmodule Backplane.Services.WebFetch do
  @moduledoc """
  Managed MCP service providing `web::fetch`.

  Fetches an HTTP(S) URL and returns cleaned Markdown content.
  """

  @behaviour Backplane.Services.ManagedService

  @prefix "web"
  @max_body_bytes 10_000_000
  @user_agent "Backplane-WebFetch/1.0 (+https://github.com/gsmlg-opt/backplane)"
  @ignored_tags ~w(script style nav header footer aside svg canvas)

  @impl true
  def prefix, do: @prefix

  @impl true
  def enabled?, do: Backplane.Settings.get("services.web.enabled") == true

  @impl true
  def tools do
    [
      %{
        name: "web::fetch",
        description:
          "Fetches an HTTP(S) URL and converts the content to clean, readable Markdown. Supports optional instructions for targeted extraction.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "url" => %{
              "type" => "string",
              "format" => "uri",
              "description" => "Full URL to fetch (http or https only)"
            },
            "instructions" => %{
              "type" => "string",
              "description" => "Optional extraction or summarization instruction"
            }
          },
          "required" => ["url"],
          "additionalProperties" => false
        },
        handler: &handle_fetch/1
      }
    ]
  end

  def handle_fetch(%{"url" => url} = params) when is_binary(url) do
    instructions = Map.get(params, "instructions")

    with :ok <- validate_url(url),
         {:ok, response} <- fetch_url(url),
         {:ok, markdown, metadata} <- convert_to_markdown(response, instructions) do
      {:ok, Map.put(metadata, :content, markdown)}
    else
      {:error, reason} -> {:error, %{code: "web_fetch_error", message: to_string(reason)}}
    end
  rescue
    e -> {:error, %{code: "web_fetch_error", message: Exception.message(e)}}
  end

  def handle_fetch(_args), do: {:error, %{code: "web_fetch_error", message: "missing url"}}

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _ ->
        {:error, "URL must be absolute and use http or https"}
    end
  end

  defp fetch_url(url) do
    options =
      [
        url: url,
        headers: [{"user-agent", @user_agent}],
        redirect: true,
        max_redirects: 5,
        receive_timeout: 15_000,
        decode_body: false
      ]
      |> Keyword.merge(Application.get_env(:backplane, :web_fetch_req_options, []))

    case Req.get(options) do
      {:ok, %Req.Response{status: status, body: body} = resp} when status in 200..299 ->
        if byte_size(body) <= @max_body_bytes do
          {:ok, %{response: resp, url: url}}
        else
          {:error, "response body exceeds #{@max_body_bytes} bytes"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, err} ->
        {:error, error_message(err)}
    end
  end

  defp convert_to_markdown(%{response: response, url: url}, _instructions) do
    body = response.body || ""
    headers = response.headers
    fetched_at = DateTime.utc_now() |> DateTime.to_iso8601()

    if html_response?(headers) do
      html = LazyHTML.from_document(body)
      tree = html |> LazyHTML.to_tree() |> remove_ignored_nodes()
      markdown = tree |> nodes_to_markdown() |> clean_markdown()

      metadata = %{
        title: extract_title(html),
        url: url,
        fetched_at: fetched_at,
        length: byte_size(markdown)
      }

      {:ok, markdown, metadata}
    else
      markdown = "```\n#{body}\n```"

      {:ok, markdown,
       %{
         title: "Raw Content",
         url: url,
         fetched_at: fetched_at,
         length: byte_size(markdown)
       }}
    end
  end

  defp html_response?(headers) do
    headers
    |> Map.get("content-type", [])
    |> List.first("")
    |> String.downcase()
    |> String.starts_with?("text/html")
  end

  defp extract_title(html) do
    case html |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() do
      "" -> "Untitled Page"
      title -> title
    end
  end

  defp error_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)

  defp remove_ignored_nodes(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      {tag, _attrs, _children} when tag in @ignored_tags ->
        []

      {tag, attrs, children} ->
        [{tag, attrs, remove_ignored_nodes(children)}]

      {:comment, _content} ->
        []

      node ->
        [node]
    end)
  end

  defp nodes_to_markdown(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&node_to_markdown/1)
    |> Enum.join("")
  end

  defp node_to_markdown(text) when is_binary(text), do: normalize_inline(text)

  defp node_to_markdown({tag, attrs, children}) do
    content = nodes_to_markdown(children)

    case tag do
      "h1" -> block("# " <> clean_inline(content))
      "h2" -> block("## " <> clean_inline(content))
      "h3" -> block("### " <> clean_inline(content))
      "h4" -> block("#### " <> clean_inline(content))
      "h5" -> block("##### " <> clean_inline(content))
      "h6" -> block("###### " <> clean_inline(content))
      "p" -> block(clean_inline(content))
      "br" -> "\n"
      "strong" -> "**" <> clean_inline(content) <> "**"
      "b" -> "**" <> clean_inline(content) <> "**"
      "em" -> "*" <> clean_inline(content) <> "*"
      "i" -> "*" <> clean_inline(content) <> "*"
      "code" -> "`" <> clean_inline(content) <> "`"
      "pre" -> "```\n" <> String.trim(content) <> "\n```\n\n"
      "blockquote" -> content |> clean_markdown() |> prefix_lines("> ") |> block()
      "a" -> link_markdown(attrs, content)
      "img" -> image_markdown(attrs)
      "li" -> "- " <> clean_inline(content) <> "\n"
      "ul" -> "\n" <> content <> "\n"
      "ol" -> "\n" <> content <> "\n"
      "tr" -> clean_inline(content) <> "\n"
      "th" -> clean_inline(content) <> " | "
      "td" -> clean_inline(content) <> " | "
      _ -> content
    end
  end

  defp node_to_markdown(_other), do: ""

  defp link_markdown(attrs, content) do
    text = clean_inline(content)

    case attr(attrs, "href") do
      nil -> text
      "" -> text
      href -> "[" <> text <> "](" <> href <> ")"
    end
  end

  defp image_markdown(attrs) do
    alt = attr(attrs, "alt") || ""

    case attr(attrs, "src") do
      nil -> ""
      "" -> ""
      src -> "![" <> alt <> "](" <> src <> ")"
    end
  end

  defp attr(attrs, name) do
    attrs
    |> List.keyfind(name, 0)
    |> case do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp block(content), do: String.trim(content) <> "\n\n"

  defp prefix_lines(content, prefix) do
    content
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end

  defp normalize_inline(text), do: Regex.replace(~r/\s+/u, text, " ")
  defp clean_inline(text), do: text |> normalize_inline() |> String.trim()

  defp clean_markdown(markdown) do
    markdown
    |> String.replace(~r/[ \t]+\n/u, "\n")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end
end
