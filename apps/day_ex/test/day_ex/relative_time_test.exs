defmodule DayEx.RelativeTimeTest do
  use ExUnit.Case, async: true

  describe "from/2,3" do
    test "seconds ago" do
      now = DayEx.now()
      past = DayEx.subtract(now, 30, :second)
      assert DayEx.from(past, now) == "a few seconds ago"
    end

    test "minutes ago" do
      now = DayEx.now()
      past = DayEx.subtract(now, 5, :minute)
      assert DayEx.from(past, now) == "5 minutes ago"
    end

    test "hours ago" do
      now = DayEx.now()
      past = DayEx.subtract(now, 3, :hour)
      assert DayEx.from(past, now) == "3 hours ago"
    end

    test "days ago" do
      now = DayEx.now()
      past = DayEx.subtract(now, 5, :day)
      assert DayEx.from(past, now) == "5 days ago"
    end

    test "a month ago" do
      now = DayEx.now()
      past = DayEx.subtract(now, 30, :day)
      assert DayEx.from(past, now) == "a month ago"
    end

    test "without suffix" do
      now = DayEx.now()
      past = DayEx.subtract(now, 5, :minute)
      assert DayEx.from(past, now, true) == "5 minutes"
    end

    test "future — in N" do
      now = DayEx.now()
      future = DayEx.add(now, 5, :minute)
      assert DayEx.from(future, now) == "in 5 minutes"
    end
  end

  describe "to/2,3" do
    test "to future" do
      now = DayEx.now()
      future = DayEx.add(now, 5, :minute)
      assert DayEx.to(now, future) == "in 5 minutes"
    end

    test "to past" do
      now = DayEx.now()
      past = DayEx.subtract(now, 5, :minute)
      assert DayEx.to(now, past) == "5 minutes ago"
    end
  end

  describe "thresholds" do
    test "0-44s = a few seconds" do
      now = DayEx.now()
      assert DayEx.from(DayEx.subtract(now, 10, :second), now) == "a few seconds ago"
      assert DayEx.from(DayEx.subtract(now, 44, :second), now) == "a few seconds ago"
    end

    test "45-89s = a minute" do
      now = DayEx.now()
      assert DayEx.from(DayEx.subtract(now, 50, :second), now) == "a minute ago"
    end

    test "90s-44min = N minutes" do
      now = DayEx.now()
      assert DayEx.from(DayEx.subtract(now, 2, :minute), now) == "2 minutes ago"
      assert DayEx.from(DayEx.subtract(now, 44, :minute), now) == "44 minutes ago"
    end

    test "45-89min = an hour" do
      now = DayEx.now()
      assert DayEx.from(DayEx.subtract(now, 50, :minute), now) == "an hour ago"
    end

    test "90min-21hr = N hours" do
      now = DayEx.now()
      assert DayEx.from(DayEx.subtract(now, 2, :hour), now) == "2 hours ago"
    end

    test "22-35hr = a day" do
      now = DayEx.now()
      assert DayEx.from(DayEx.subtract(now, 24, :hour), now) == "a day ago"
    end

    test "36hr-25d = N days" do
      now = DayEx.now()
      assert DayEx.from(DayEx.subtract(now, 5, :day), now) == "5 days ago"
    end
  end
end
