defmodule Backplane.WebOriginsTest do
  use ExUnit.Case, async: false

  alias Backplane.WebOrigins

  setup do
    old_api_url = Application.get_env(:backplane, :api_url)
    old_admin_url = Application.get_env(:backplane, :admin_url)

    on_exit(fn ->
      restore_env(:api_url, old_api_url)
      restore_env(:admin_url, old_admin_url)
    end)

    :ok
  end

  test "returns configured base URLs without trailing slashes" do
    Application.put_env(:backplane, :api_url, "http://api.example.test/")
    Application.put_env(:backplane, :admin_url, "http://admin.example.test/")

    assert WebOrigins.api_base_url() == "http://api.example.test"
    assert WebOrigins.admin_base_url() == "http://admin.example.test"
  end

  test "joins paths onto configured origins" do
    Application.put_env(:backplane, :api_url, "http://api.example.test")
    Application.put_env(:backplane, :admin_url, "http://admin.example.test")

    assert WebOrigins.api_url("/mcp") == "http://api.example.test/mcp"
    assert WebOrigins.api_url("mcp") == "http://api.example.test/mcp"

    assert WebOrigins.admin_url("/dashboard/overview") ==
             "http://admin.example.test/dashboard/overview"
  end

  test "uses development defaults when origins are not configured" do
    Application.delete_env(:backplane, :api_url)
    Application.delete_env(:backplane, :admin_url)

    assert WebOrigins.api_base_url() == "http://localhost:4220"
    assert WebOrigins.admin_base_url() == "http://localhost:4221"
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
