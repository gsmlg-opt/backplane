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

  describe "now/0" do
    test "returns current UTC time" do
      %DayEx{datetime: dt, locale: :en} = DayEx.now()
      assert %DateTime{} = dt
      assert dt.time_zone == "Etc/UTC"
    end
  end

  describe "now/1" do
    test "returns current time with locale" do
      %DayEx{locale: :fr} = DayEx.now(:fr)
    end
  end

  describe "parse/1" do
    test "parses ISO 8601 string" do
      assert {:ok, %DayEx{datetime: dt}} = DayEx.parse("2024-01-15T10:30:00Z")
      assert dt.year == 2024
      assert dt.month == 1
      assert dt.day == 15
      assert dt.hour == 10
      assert dt.minute == 30
    end

    test "parses ISO 8601 string with offset" do
      assert {:ok, %DayEx{datetime: dt}} = DayEx.parse("2024-01-15T10:30:00+05:30")
      assert %DateTime{} = dt
    end

    test "parses date-only string" do
      assert {:ok, %DayEx{datetime: dt}} = DayEx.parse("2024-01-15")
      assert %NaiveDateTime{} = dt
      assert dt.year == 2024
      assert dt.month == 1
      assert dt.day == 15
      assert dt.hour == 0
    end

    test "parses unix timestamp integer (seconds)" do
      assert {:ok, %DayEx{datetime: dt}} = DayEx.parse(1_705_312_200)
      assert %DateTime{} = dt
    end

    test "parses unix timestamp float (seconds)" do
      assert {:ok, %DayEx{datetime: dt}} = DayEx.parse(1_705_312_200.123)
      assert %DateTime{} = dt
    end

    test "parses DateTime" do
      {:ok, input, _} = DateTime.from_iso8601("2024-01-15T10:30:00Z")
      assert {:ok, %DayEx{datetime: ^input}} = DayEx.parse(input)
    end

    test "parses NaiveDateTime" do
      input = ~N[2024-01-15 10:30:00]
      assert {:ok, %DayEx{datetime: ^input}} = DayEx.parse(input)
    end

    test "parses Date" do
      input = ~D[2024-01-15]
      assert {:ok, %DayEx{datetime: dt}} = DayEx.parse(input)
      assert %NaiveDateTime{} = dt
      assert dt.year == 2024
      assert dt.month == 1
      assert dt.day == 15
    end

    test "parses %DayEx{} (clone)" do
      {:ok, original} = DayEx.parse("2024-01-15T10:30:00Z")
      assert {:ok, clone} = DayEx.parse(original)
      assert clone.datetime == original.datetime
    end

    test "returns error for invalid input" do
      assert {:error, _} = DayEx.parse("not-a-date")
    end
  end

  describe "parse!/1" do
    test "returns DayEx on success" do
      assert %DayEx{} = DayEx.parse!("2024-01-15T10:30:00Z")
    end

    test "raises on failure" do
      assert_raise ArgumentError, fn -> DayEx.parse!("not-a-date") end
    end
  end

  describe "unix/1" do
    test "creates from unix timestamp in seconds" do
      %DayEx{datetime: dt} = DayEx.unix(1_705_312_200)
      assert %DateTime{} = dt
      assert dt.time_zone == "Etc/UTC"
    end
  end

  describe "utc/0" do
    test "returns current UTC time" do
      %DayEx{datetime: dt} = DayEx.utc()
      assert dt.time_zone == "Etc/UTC"
    end
  end

  describe "utc/1" do
    test "parses as UTC" do
      %DayEx{datetime: dt} = DayEx.utc("2024-01-15T10:30:00+05:30")
      assert dt.time_zone == "Etc/UTC"
    end
  end
end
