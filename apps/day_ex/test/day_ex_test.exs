defmodule DayExTest do
  use ExUnit.Case, async: true

  describe "String.Chars" do
    test "converts to ISO 8601 string" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-01-15T10:30:00Z")
      d = %DayEx{datetime: dt}
      assert to_string(d) == "2024-01-15T10:30:00Z"
    end

    test "converts NaiveDateTime to string" do
      ndt = ~N[2024-01-15 10:30:00]
      d = %DayEx{datetime: ndt}
      assert to_string(d) == "2024-01-15T10:30:00"
    end
  end

  describe "Inspect" do
    test "shows readable format with timezone" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-01-15T10:30:00Z")
      d = %DayEx{datetime: dt}
      assert inspect(d) == "#DayEx<2024-01-15T10:30:00Z en>"
    end

    test "shows readable format without timezone" do
      ndt = ~N[2024-01-15 10:30:00]
      d = %DayEx{datetime: ndt}
      assert inspect(d) == "#DayEx<2024-01-15T10:30:00 en>"
    end

    test "shows locale" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-01-15T10:30:00Z")
      d = %DayEx{datetime: dt, locale: :fr}
      assert inspect(d) == "#DayEx<2024-01-15T10:30:00Z fr>"
    end
  end

  describe "Compare" do
    test "sorts DayEx values" do
      {:ok, dt1, _} = DateTime.from_iso8601("2024-01-15T10:00:00Z")
      {:ok, dt2, _} = DateTime.from_iso8601("2024-01-15T12:00:00Z")
      {:ok, dt3, _} = DateTime.from_iso8601("2024-01-15T08:00:00Z")

      list = [%DayEx{datetime: dt1}, %DayEx{datetime: dt2}, %DayEx{datetime: dt3}]
      sorted = Enum.sort(list, DayEx)

      assert [%DayEx{datetime: ^dt3}, %DayEx{datetime: ^dt1}, %DayEx{datetime: ^dt2}] = sorted
    end
  end
end
