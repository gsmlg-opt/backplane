defmodule Backplane.SettingsTest do
  use Backplane.DataCase, async: false

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Settings
  alias Backplane.Settings.Setting

  describe "list_definitions/0" do
    test "does not expose internal service toggles as settings options" do
      assert Settings.list_definitions() == []
    end
  end

  describe "defaults" do
    test "smart auto model has no default target models" do
      key = "llm.auto_models.smart.targets"

      Repo.delete_all(from(s in Setting, where: s.key == ^key))
      :ets.delete(:backplane_settings, key)

      assert Settings.get(key) == []
    end

    test "skill archive defaults are available" do
      assert Settings.get("skills.archive.max_bytes") == 20_000_000
      assert Settings.get("skills.archive.max_files") == 500
      assert Settings.get("skills.blob.local_root") == nil
    end
  end
end
