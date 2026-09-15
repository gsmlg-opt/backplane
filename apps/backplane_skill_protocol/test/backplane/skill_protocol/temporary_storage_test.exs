defmodule Backplane.SkillProtocol.TemporaryStorageTest do
  use ExUnit.Case, async: true

  alias Backplane.SkillProtocol.TemporaryStorage

  @moduletag :tmp_dir

  test "collisions do not modify or remove an unowned sentinel", %{tmp_dir: tmp_dir} do
    sentinel = Path.join(tmp_dir, "private.sentinel")
    File.mkdir!(sentinel)
    marker = Path.join(sentinel, "marker")
    File.write!(marker, "untouched")
    File.chmod!(sentinel, 0o755)

    assert {:error, :collision} =
             TemporaryStorage.directory(tmp_dir, "private",
               attempts: 2,
               suffix: fn -> "sentinel" end
             )

    assert File.read!(marker) == "untouched"
    assert_expected_mode(permission(sentinel), 0o755)
  end

  test "owned directories and files have owner-only permissions", %{tmp_dir: tmp_dir} do
    assert {:ok, directory} =
             TemporaryStorage.directory(tmp_dir, "private", suffix: fn -> "owned" end)

    file = Path.join(directory, "artifact")
    assert :ok = TemporaryStorage.write_file(file, "secret")
    assert_expected_mode(permission(directory), 0o700)
    assert_expected_mode(permission(file), 0o600)
  end

  defp permission(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777)
  end

  defp assert_expected_mode(actual, expected) do
    if match?({:unix, _}, :os.type()),
      do: assert(actual == expected),
      else: assert(is_integer(actual))
  end
end
