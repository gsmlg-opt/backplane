defmodule DayEx.FormatTest do
  use ExUnit.Case, async: true

  describe "tokenize/1" do
    test "basic tokens" do
      assert DayEx.Format.tokenize("YYYY-MM-DD") == [
               {:token, "YYYY"},
               {:literal, "-"},
               {:token, "MM"},
               {:literal, "-"},
               {:token, "DD"}
             ]
    end

    test "escaped text" do
      assert DayEx.Format.tokenize("[Year:] YYYY") == [
               {:literal, "Year:"},
               {:literal, " "},
               {:token, "YYYY"}
             ]
    end

    test "greedy matching — MMMM before MMM" do
      assert DayEx.Format.tokenize("MMMM") == [{:token, "MMMM"}]
    end

    test "adjacent tokens" do
      tokens = DayEx.Format.tokenize("YYYYMMDDHHmmss")

      assert tokens == [
               {:token, "YYYY"},
               {:token, "MM"},
               {:token, "DD"},
               {:token, "HH"},
               {:token, "mm"},
               {:token, "ss"}
             ]
    end
  end

  describe "format/2" do
    setup do
      d = DayEx.parse!("2024-03-15T14:30:45.123Z")
      %{d: d}
    end

    test "YYYY-MM-DD", %{d: d} do
      assert DayEx.Format.format(d, "YYYY-MM-DD") == "2024-03-15"
    end

    test "HH:mm:ss", %{d: d} do
      assert DayEx.Format.format(d, "HH:mm:ss") == "14:30:45"
    end

    test "h:mm A", %{d: d} do
      assert DayEx.Format.format(d, "h:mm A") == "2:30 PM"
    end

    test "full format", %{d: d} do
      assert DayEx.Format.format(d, "YYYY/MM/DD HH:mm:ss.SSS") == "2024/03/15 14:30:45.123"
    end

    test "day names — dddd ddd dd d", %{d: d} do
      assert DayEx.Format.format(d, "dddd") == "Friday"
      assert DayEx.Format.format(d, "ddd") == "Fri"
      assert DayEx.Format.format(d, "dd") == "Fr"
      assert DayEx.Format.format(d, "d") == "5"
    end

    test "month names — MMMM MMM", %{d: d} do
      assert DayEx.Format.format(d, "MMMM") == "March"
      assert DayEx.Format.format(d, "MMM") == "Mar"
    end

    test "two-digit year — YY", %{d: d} do
      assert DayEx.Format.format(d, "YY") == "24"
    end

    test "unpadded month/day — M D", %{d: d} do
      assert DayEx.Format.format(d, "M/D") == "3/15"
    end

    test "12-hour — h hh", %{d: d} do
      assert DayEx.Format.format(d, "h") == "2"
      assert DayEx.Format.format(d, "hh") == "02"
    end

    test "milliseconds — SSS", %{d: d} do
      assert DayEx.Format.format(d, "SSS") == "123"
    end

    test "timezone offset — Z ZZ" do
      d = DayEx.parse!("2024-03-15T14:30:45Z")
      assert DayEx.Format.format(d, "Z") == "+00:00"
      assert DayEx.Format.format(d, "ZZ") == "+0000"
    end

    test "am/pm — A a" do
      morning = DayEx.parse!("2024-03-15T08:30:00Z")
      afternoon = DayEx.parse!("2024-03-15T14:30:00Z")
      assert DayEx.Format.format(morning, "A") == "AM"
      assert DayEx.Format.format(afternoon, "a") == "pm"
    end

    test "unix timestamps — X x", %{d: d} do
      x_result = DayEx.Format.format(d, "X")
      assert String.to_integer(x_result) > 0
    end

    test "quarter — Q", %{d: d} do
      assert DayEx.Format.format(d, "Q") == "1"
    end

    test "ordinal day — Do", %{d: d} do
      assert DayEx.Format.format(d, "Do") == "15th"
    end

    test "1-24 hour — k kk" do
      midnight = DayEx.parse!("2024-03-15T00:00:00Z")
      assert DayEx.Format.format(midnight, "k") == "24"
      assert DayEx.Format.format(midnight, "kk") == "24"
    end

    test "escape with brackets", %{d: d} do
      assert DayEx.Format.format(d, "[Today is] YYYY-MM-DD") == "Today is 2024-03-15"
    end

    test "ISO week — W WW", %{d: d} do
      result = DayEx.Format.format(d, "W")
      assert is_binary(result)
      assert String.to_integer(result) > 0
    end

    test "week of year — w ww", %{d: d} do
      result = DayEx.Format.format(d, "w")
      assert is_binary(result)
      assert String.to_integer(result) > 0
    end

    test "localized format tokens — LT LTS L LL LLL LLLL", %{d: d} do
      assert DayEx.Format.format(d, "LT") == "2:30 PM"
      assert DayEx.Format.format(d, "LTS") == "2:30:45 PM"
      assert DayEx.Format.format(d, "L") == "03/15/2024"
      assert DayEx.Format.format(d, "LL") == "March 15, 2024"
      assert DayEx.Format.format(d, "LLL") == "March 15, 2024 2:30 PM"
      assert DayEx.Format.format(d, "LLLL") == "Friday, March 15, 2024 2:30 PM"
    end

    test "short localized format tokens — l ll lll llll", %{d: d} do
      assert DayEx.Format.format(d, "l") == "3/15/2024"
      assert DayEx.Format.format(d, "ll") == "Mar 15, 2024"
      assert DayEx.Format.format(d, "lll") == "Mar 15, 2024 2:30 PM"
      assert DayEx.Format.format(d, "llll") == "Fri, Mar 15, 2024 2:30 PM"
    end

    test "localized format tokens use the selected locale", %{d: d} do
      d = DayEx.locale(d, :fr)

      assert DayEx.Format.format(d, "L") == "15/03/2024"
      assert DayEx.Format.format(d, "LL") == "15 mars 2024"
      assert DayEx.Format.format(d, "LLLL") == "vendredi 15 mars 2024 14:30"
    end
  end
end
