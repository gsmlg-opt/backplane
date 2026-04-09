defmodule DayEx.LocaleTest do
  use ExUnit.Case, async: true

  describe "Chinese locale" do
    test "month name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:zh)
      assert DayEx.format(d, "MMMM") == "三月"
    end

    test "weekday name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:zh)
      assert DayEx.format(d, "dddd") == "星期五"
    end
  end

  describe "Japanese locale" do
    test "month name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:ja)
      assert DayEx.format(d, "MMMM") == "3月"
    end
  end

  describe "Korean locale" do
    test "month name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:ko)
      assert DayEx.format(d, "MMMM") == "3월"
    end
  end

  describe "Spanish locale" do
    test "month name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:es)
      assert DayEx.format(d, "MMMM") == "marzo"
    end

    test "weekday name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:es)
      assert DayEx.format(d, "dddd") == "viernes"
    end
  end

  describe "French locale" do
    test "month name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:fr)
      assert DayEx.format(d, "MMMM") == "mars"
    end

    test "weekday name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:fr)
      assert DayEx.format(d, "dddd") == "vendredi"
    end
  end

  describe "German locale" do
    test "month name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:de)
      assert DayEx.format(d, "MMMM") == "März"
    end

    test "weekday name" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:de)
      assert DayEx.format(d, "dddd") == "Freitag"
    end
  end

  describe "locale fallback" do
    test "unknown locale falls back to English" do
      d = DayEx.parse!("2024-03-15T00:00:00Z") |> DayEx.locale(:xx)
      assert DayEx.format(d, "MMMM") == "March"
    end
  end
end
