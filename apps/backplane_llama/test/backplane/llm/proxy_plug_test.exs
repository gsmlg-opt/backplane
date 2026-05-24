defmodule Backplane.LLM.ProxyPlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Backplane.LLM.ProxyPlug

  describe "call/2" do
    test "passes through non-/llm paths unchanged" do
      conn = conn(:get, "/admin/dashboard/overview")
      result = ProxyPlug.call(conn, ProxyPlug.init([]))

      assert result.path_info == ["admin", "dashboard", "overview"]
      assert result.request_path == "/admin/dashboard/overview"
      refute result.halted
    end

    test "passes through /llm-other paths (not exact prefix)" do
      conn = conn(:get, "/llm-other/foo")
      result = ProxyPlug.call(conn, ProxyPlug.init([]))

      assert result.path_info == ["llm-other", "foo"]
      refute result.halted
    end

    test "passes through root path" do
      conn = conn(:get, "/")
      result = ProxyPlug.call(conn, ProxyPlug.init([]))

      assert result.path_info == []
      refute result.halted
    end

    test "passes through LLM admin API paths" do
      conn = conn(:get, "/api/llm/providers")
      result = ProxyPlug.call(conn, ProxyPlug.init([]))

      assert result.path_info == ["api", "llm", "providers"]
      assert result.request_path == "/api/llm/providers"
      refute result.halted
    end
  end
end
