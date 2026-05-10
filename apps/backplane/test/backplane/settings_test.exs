defmodule Backplane.SettingsTest do
  use Backplane.DataCase, async: false

  alias Backplane.Settings

  describe "list_definitions/0" do
    test "does not expose internal service toggles as settings options" do
      assert Settings.list_definitions() == []
    end
  end
end
