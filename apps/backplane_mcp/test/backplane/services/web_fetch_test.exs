defmodule Backplane.Services.WebFetchTest do
  use BackplaneMcp.DataCase, async: false

  alias Backplane.Services.{Web, WebFetch}
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  setup do
    previous = Application.get_env(:backplane, :web_fetch_req_options)
    Application.put_env(:backplane, :web_fetch_req_options, plug: {Req.Test, WebFetch})

    Settings.set("services.web.enabled", true)
    Settings.set("services.web_fetch.default_backend", "direct")
    Settings.set("services.web_fetch.firecrawl.base_url", nil)
    Settings.set("services.web_fetch.firecrawl.credential", nil)

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :web_fetch_req_options, previous)
      else
        Application.delete_env(:backplane, :web_fetch_req_options)
      end
    end)

    :ok
  end

  test "web service exposes exactly fetch, search, and x_search" do
    assert Enum.map(Web.tools(), & &1.name) == ["web::fetch", "web::search", "web::x_search"]

    tool = Enum.find(Web.tools(), &(&1.name == "web::fetch"))
    assert get_in(tool.input_schema, ["properties", "backend", "enum"]) == ~w(direct firecrawl)
    refute tool.description =~ "instructions"
  end

  test "direct fetch remains the default and returns cleaned markdown" do
    Req.Test.stub(WebFetch, fn conn ->
      assert conn.method == "GET"

      Req.Test.html(conn, """
      <!doctype html>
      <html>
        <head><title>Example Page</title><style>.hidden { display: none; }</style></head>
        <body><nav>Navigation</nav><main><h1>Hello</h1><p>This is <strong>important</strong>.</p></main></body>
      </html>
      """)
    end)

    assert {:ok, result} = WebFetch.handle_fetch(%{"url" => "https://example.test/page"})
    assert result.title == "Example Page"
    assert result.url == "https://example.test/page"
    assert result.content =~ "Hello"
    refute result.content =~ "Navigation"
    assert result.length == byte_size(result.content)
  end

  test "direct fetch preserves raw content and HTTP error behavior" do
    Req.Test.stub(WebFetch, fn conn -> Req.Test.text(conn, "plain response") end)

    assert {:ok, result} = WebFetch.handle_fetch(%{"url" => "https://example.test/plain"})
    assert result.title == "Raw Content"
    assert result.content == "```\nplain response\n```"

    Req.Test.stub(WebFetch, fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end)

    assert {:error, %{message: "HTTP 404"}} =
             WebFetch.handle_fetch(%{"url" => "https://example.test/missing"})
  end

  test "firecrawl fetch uses configured URL, bearer credential, and normalized metadata" do
    {:ok, _} = Credentials.store("firecrawl-key", "firecrawl-secret", "service")
    Settings.set("services.web_fetch.default_backend", "firecrawl")
    Settings.set("services.web_fetch.firecrawl.base_url", "https://crawl.example.test/api")
    Settings.set("services.web_fetch.firecrawl.credential", "firecrawl-key")

    Req.Test.stub(WebFetch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.method == "POST"
      assert conn.host == "crawl.example.test"
      assert conn.request_path == "/api/v2/scrape"
      assert {"authorization", "Bearer firecrawl-secret"} in conn.req_headers

      assert Jason.decode!(body) == %{
               "url" => "https://example.test/page",
               "formats" => ["markdown"]
             }

      Req.Test.json(conn, %{
        "success" => true,
        "data" => %{
          "markdown" => "# Firecrawl page",
          "metadata" => %{
            "title" => "Firecrawl Title",
            "sourceURL" => "https://example.test/final"
          }
        }
      })
    end)

    assert {:ok, result} = WebFetch.handle_fetch(%{"url" => "https://example.test/page"})
    assert result.content == "# Firecrawl page"
    assert result.title == "Firecrawl Title"
    assert result.url == "https://example.test/final"
    assert result.length == byte_size(result.content)
    assert is_binary(result.fetched_at)
  end

  test "explicit firecrawl backend requires a credential and reports provider failures" do
    assert {:error, %{code: "web_fetch_error", message: message}} =
             WebFetch.handle_fetch(%{"url" => "https://example.test", "backend" => "firecrawl"})

    assert message == "firecrawl credential is not configured"

    {:ok, _} = Credentials.store("firecrawl-key", "firecrawl-secret", "service")
    Settings.set("services.web_fetch.firecrawl.credential", "firecrawl-key")

    Req.Test.stub(WebFetch, fn conn ->
      Req.Test.json(conn, %{"success" => false, "error" => "firecrawl-secret"})
    end)

    assert {:error, %{code: "web_fetch_error", message: message}} =
             WebFetch.handle_fetch(%{"url" => "https://example.test", "backend" => "firecrawl"})

    assert message == "Firecrawl API request failed"
    refute message =~ "firecrawl-secret"
  end

  test "firecrawl rejects non-2xx, malformed metadata, and oversized markdown" do
    {:ok, _} = Credentials.store("firecrawl-key", "firecrawl-secret", "service")
    Settings.set("services.web_fetch.firecrawl.credential", "firecrawl-key")

    Req.Test.stub(WebFetch, fn conn -> Plug.Conn.send_resp(conn, 429, "firecrawl-secret") end)

    assert {:error, %{message: "Firecrawl HTTP 429"}} =
             WebFetch.handle_fetch(%{"url" => "https://example.test", "backend" => "firecrawl"})

    Req.Test.stub(WebFetch, fn conn ->
      Req.Test.json(conn, %{
        "success" => true,
        "data" => %{"markdown" => "content", "metadata" => ["invalid"]}
      })
    end)

    assert {:error, %{message: "Firecrawl returned a malformed response"}} =
             WebFetch.handle_fetch(%{"url" => "https://example.test", "backend" => "firecrawl"})

    Req.Test.stub(WebFetch, fn conn ->
      Req.Test.json(conn, %{
        "success" => true,
        "data" => %{"markdown" => String.duplicate("x", 10_000_001), "metadata" => %{}}
      })
    end)

    assert {:error, %{message: "response body exceeds 10000000 bytes"}} =
             WebFetch.handle_fetch(%{"url" => "https://example.test", "backend" => "firecrawl"})
  end

  test "rejects unsupported URLs and global disable" do
    assert {:error, %{code: "web_fetch_error", message: message}} =
             WebFetch.handle_fetch(%{"url" => "file:///etc/passwd"})

    assert message =~ "http or https"

    Settings.set("services.web.enabled", false)

    assert {:error, %{code: "web_fetch_error", message: "web service is disabled"}} =
             WebFetch.handle_fetch(%{"url" => "https://example.test"})
  end
end
