defmodule Backplane.Services.WebFetchTest do
  use ExUnit.Case, async: false

  alias Backplane.Services.WebFetch

  setup do
    previous = Application.get_env(:backplane, :web_fetch_req_options)
    Application.put_env(:backplane, :web_fetch_req_options, plug: {Req.Test, WebFetch})

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :web_fetch_req_options, previous)
      else
        Application.delete_env(:backplane, :web_fetch_req_options)
      end
    end)

    :ok
  end

  test "tools/0 emits web::fetch with ManagedService-shaped fields" do
    [tool] = WebFetch.tools()
    assert tool.name == "web::fetch"
    assert is_binary(tool.description)
    assert is_map(tool.input_schema)
    assert is_function(tool.handler, 1)
  end

  test "handle_fetch/1 returns cleaned markdown for HTML" do
    Req.Test.stub(WebFetch, fn conn ->
      Req.Test.html(conn, """
      <!doctype html>
      <html>
        <head><title>Example Page</title><style>.hidden { display: none; }</style></head>
        <body>
          <header>Header chrome</header>
          <nav>Navigation</nav>
          <main>
            <h1>Hello</h1>
            <p>This is <strong>important</strong>.</p>
          </main>
          <script>window.bad = true;</script>
        </body>
      </html>
      """)
    end)

    assert {:ok, result} = WebFetch.handle_fetch(%{"url" => "https://example.test/page"})
    assert result.title == "Example Page"
    assert result.url == "https://example.test/page"
    assert result.content =~ "Hello"
    assert result.content =~ "important"
    refute result.content =~ "Navigation"
    refute result.content =~ "window.bad"
    assert result.length == byte_size(result.content)
  end

  test "handle_fetch/1 wraps non-HTML content" do
    Req.Test.stub(WebFetch, fn conn ->
      Req.Test.text(conn, "plain response")
    end)

    assert {:ok, result} = WebFetch.handle_fetch(%{"url" => "https://example.test/plain"})
    assert result.title == "Raw Content"
    assert result.content == "```\nplain response\n```"
  end

  test "handle_fetch/1 rejects unsupported URLs and HTTP errors" do
    assert {:error, %{code: "web_fetch_error", message: message}} =
             WebFetch.handle_fetch(%{"url" => "file:///etc/passwd"})

    assert message =~ "http or https"

    Req.Test.stub(WebFetch, fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    assert {:error, %{code: "web_fetch_error", message: "HTTP 404"}} =
             WebFetch.handle_fetch(%{"url" => "https://example.test/missing"})
  end
end
