defmodule Backplane.Skills.SearchCategoriesTest do
  use BackplaneSkills.DataCase, async: false

  alias Backplane.Settings
  alias Backplane.Settings.Setting
  alias Backplane.Skills.SearchCategories

  setup do
    key = SearchCategories.key()
    previous = :ets.lookup(:backplane_settings, key)
    if setting = Repo.get(Setting, key), do: Repo.delete!(setting)
    :ets.delete(:backplane_settings, key)

    on_exit(fn ->
      :ets.delete(:backplane_settings, key)
      :ets.insert(:backplane_settings, previous)
    end)

    :ok
  end

  test "defaults to an empty list" do
    assert SearchCategories.key() == "skills.search_categories"
    assert SearchCategories.list() == []
  end

  test "saves normalized categories and broadcasts the persisted string list" do
    :ok = Phoenix.PubSub.subscribe(Backplane.PubSub, Settings.topic())
    key = SearchCategories.key()
    text = "  Android debugging \r\n\r\niOS debugging\nandroid debugging\n调试工具\t使用  "
    categories = ["Android debugging", "iOS debugging", "调试工具 使用"]

    assert {:ok, ^categories} = SearchCategories.save(text)
    assert SearchCategories.list() == categories
    assert Repo.get!(Setting, key).value == %{"v" => categories}
    assert_receive {:setting_changed, ^key, ^categories}

    assert {:ok, []} = SearchCategories.save(" \n\r\n ")
    assert SearchCategories.list() == []
    assert Repo.get!(Setting, key).value == %{"v" => []}
  end

  test "invalid or oversized input preserves the saved categories" do
    assert {:ok, ["Android debugging"]} = SearchCategories.save("Android debugging")

    assert {:error, :invalid_categories} = SearchCategories.save("Android\0debugging")
    assert {:error, :invalid_categories} = SearchCategories.save(<<255>>)
    assert {:error, :invalid_categories} = SearchCategories.save(["Android debugging"])
    assert {:error, :category_too_long} = SearchCategories.save(String.duplicate("a", 513))
    assert {:error, :text_too_large} = SearchCategories.save(String.duplicate("a", 32_769))

    assert {:error, :too_many_categories} =
             SearchCategories.save(Enum.map_join(1..33, "\n", &"Category #{&1}"))

    assert SearchCategories.list() == ["Android debugging"]
  end

  test "reconnect reads persisted changes even when the local Settings cache is older" do
    assert {:ok, ["Android debugging"]} = SearchCategories.save("Android debugging")
    key = SearchCategories.key()

    Repo.get!(Setting, key)
    |> Ecto.Changeset.change(value: %{"v" => ["iOS debugging"]})
    |> Repo.update!()

    assert Settings.get(key) == ["Android debugging"]
    assert SearchCategories.list() == ["iOS debugging"]
  end
end
