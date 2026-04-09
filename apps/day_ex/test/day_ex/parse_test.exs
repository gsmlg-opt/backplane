defmodule DayEx.ParseTest do
  use ExUnit.Case, async: true

  describe "parse with format string" do
    test "YYYY-MM-DD" do
      assert {:ok, d} = DayEx.parse("2024-03-15", "YYYY-MM-DD")
      assert DayEx.year(d) == 2024
      assert DayEx.month(d) == 3
      assert DayEx.date(d) == 15
    end

    test "MM/DD/YYYY" do
      assert {:ok, d} = DayEx.parse("03/15/2024", "MM/DD/YYYY")
      assert DayEx.month(d) == 3
      assert DayEx.date(d) == 15
      assert DayEx.year(d) == 2024
    end

    test "YYYY-MM-DD HH:mm:ss" do
      assert {:ok, d} = DayEx.parse("2024-03-15 14:30:45", "YYYY-MM-DD HH:mm:ss")
      assert DayEx.hour(d) == 14
      assert DayEx.minute(d) == 30
      assert DayEx.second(d) == 45
    end

    test "h:mm A (12-hour)" do
      assert {:ok, d} = DayEx.parse("2:30 PM", "h:mm A")
      assert DayEx.hour(d) == 14
      assert DayEx.minute(d) == 30
    end

    test "DD-MMM-YYYY" do
      assert {:ok, d} = DayEx.parse("15-Mar-2024", "DD-MMM-YYYY")
      assert DayEx.date(d) == 15
      assert DayEx.month(d) == 3
      assert DayEx.year(d) == 2024
    end

    test "invalid input returns error" do
      assert {:error, _} = DayEx.parse("not-valid", "YYYY-MM-DD")
    end
  end

  describe "parse!/2" do
    test "succeeds" do
      assert %DayEx{} = DayEx.parse!("2024-03-15", "YYYY-MM-DD")
    end

    test "raises on failure" do
      assert_raise ArgumentError, fn -> DayEx.parse!("bad", "YYYY-MM-DD") end
    end
  end

  describe "parse/3 with locale" do
    test "parses with locale" do
      assert {:ok, d} = DayEx.parse("2024-03-15", "YYYY-MM-DD", :fr)
      assert d.locale == :fr
    end
  end
end
