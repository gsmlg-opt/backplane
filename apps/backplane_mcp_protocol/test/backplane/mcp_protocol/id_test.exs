defmodule Backplane.McpProtocol.IdTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Id

  describe "opaque IDs" do
    test "generated IDs are unique, URL-safe, and carry a timestamp" do
      first = Id.generate()
      second = Id.generate()

      assert is_binary(first)
      assert is_binary(second)
      assert first != second
      assert Id.valid?(first)
      assert {:ok, _bytes} = Base.url_decode64(first)

      timestamp = Id.timestamp_from_id(first)
      assert is_integer(timestamp)
      assert timestamp <= System.system_time(:nanosecond)
      assert timestamp > System.system_time(:nanosecond) - 1_000_000_000
    end

    test "invalid values are rejected" do
      refute Id.valid?("not an id")
      refute Id.valid?("")
      refute Id.valid?(nil)
      assert is_nil(Id.timestamp_from_id("not an id"))
    end
  end

  describe "request IDs" do
    test "request IDs use a dedicated prefix over a valid opaque ID" do
      id = Id.generate_request_id()

      assert String.starts_with?(id, "req_")
      assert Id.valid_request_id?(id)
      refute Id.valid?(id)
      refute Id.valid_progress_token?(id)
    end
  end

  describe "progress tokens" do
    test "progress tokens use a dedicated prefix over a valid opaque ID" do
      token = Id.generate_progress_token()

      assert String.starts_with?(token, "progress_")
      assert Id.valid_progress_token?(token)
      refute Id.valid?(token)
      refute Id.valid_request_id?(token)
    end
  end
end
