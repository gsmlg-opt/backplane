defmodule Backplane.JsonSchema.URIUtilTest do
  use ExUnit.Case, async: true
  alias Backplane.JsonSchema.URIUtil

  describe "resolve/2" do
    test "resolves relative URI against base URI" do
      assert URIUtil.resolve("https://example.com/schema.json", "user.json") ==
               "https://example.com/user.json"

      assert URIUtil.resolve("https://example.com/schemas/", "#/definitions/user") ==
               "https://example.com/schemas/#/definitions/user"

      assert URIUtil.resolve(nil, "https://example.com/schema.json") ==
               "https://example.com/schema.json"
    end
  end

  describe "split_fragment/1 and base/1" do
    test "splits URI into base and fragment" do
      assert URIUtil.split_fragment("https://example.com/schema#meta") ==
               {"https://example.com/schema", "meta"}

      assert URIUtil.split_fragment("#/$defs/foo") ==
               {"", "/$defs/foo"}

      assert URIUtil.base("https://example.com/schema#meta") ==
               "https://example.com/schema"

      assert URIUtil.fragment("https://example.com/schema#meta") ==
               "meta"
    end
  end
end
