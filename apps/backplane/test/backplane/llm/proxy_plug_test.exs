defmodule Backplane.LLM.ProxyPlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Backplane.LLM.ProxyPlug

  describe "call/2" do
    test "passes through non-/llm paths unchanged" do
      conn = conn(:get, "/admin/settings")
      result = ProxyPlug.call(conn, ProxyPlug.init([]))

      assert result.path_info == ["admin", "settings"]
      assert result.request_path == "/admin/settings"
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
  end
end
