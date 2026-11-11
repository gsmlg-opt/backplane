defmodule Backplane.Monitor.HttpProxyTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.HttpProxy

  @vars ~w(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "returns no options without proxy environment" do
    assert HttpProxy.connect_options("https://api.openai.com/v1/x") == []
  end

  test "uses HTTPS proxy with basic proxy authorization" do
    System.put_env("https_proxy", "http://user:pass@10.0.0.1:3128")

    assert HttpProxy.connect_options("https://api.openai.com/v1/x") == [
             proxy: {:http, "10.0.0.1", 3128, []},
             proxy_headers: [{"proxy-authorization", "Basic " <> Base.encode64("user:pass")}]
           ]
  end

  test "honours NO_PROXY domain suffixes" do
    System.put_env("HTTPS_PROXY", "http://10.0.0.1:3128")
    System.put_env("NO_PROXY", "localhost,.openai.com")

    assert HttpProxy.connect_options("https://api.openai.com/v1/x") == []
    assert [proxy: _] = HttpProxy.connect_options("https://api.deepseek.com/user/balance")
  end
end
