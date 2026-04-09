defmodule DayEx.DurationTest do
  use ExUnit.Case, async: true
  alias DayEx.Duration

  describe "new/1" do
    test "from milliseconds" do
      d = Duration.new(90_061_123)
      assert Duration.hours(d) == 25
      assert Duration.minutes(d) == 1
      assert Duration.seconds(d) == 1
      assert Duration.milliseconds(d) == 123
    end

    test "from map" do
      d = Duration.new(%{hours: 2, minutes: 30})
      assert Duration.hours(d) == 2
      assert Duration.minutes(d) == 30
    end

    test "from ISO 8601 duration string" do
      d = Duration.new("P1DT2H30M")
      assert Duration.days(d) == 1
      assert Duration.hours(d) == 2
      assert Duration.minutes(d) == 30
    end

    test "from ISO 8601 with years and months" do
      d = Duration.new("P1Y2M3D")
      assert Duration.years(d) == 1
      assert Duration.months(d) == 2
      assert Duration.days(d) == 3
    end
  end

  describe "getters" do
    test "all component getters" do
      d =
        Duration.new(%{
          years: 1,
          months: 2,
          days: 3,
          hours: 4,
          minutes: 5,
          seconds: 6,
          milliseconds: 7
        })

      assert Duration.years(d) == 1
      assert Duration.months(d) == 2
      assert Duration.days(d) == 3
      assert Duration.hours(d) == 4
      assert Duration.minutes(d) == 5
      assert Duration.seconds(d) == 6
      assert Duration.milliseconds(d) == 7
    end
  end

  describe "as_* total converters" do
    test "as_milliseconds" do
      d = Duration.new(%{seconds: 2, milliseconds: 500})
      assert Duration.as_milliseconds(d) == 2500
    end

    test "as_seconds" do
      d = Duration.new(%{minutes: 1, seconds: 30})
      assert Duration.as_seconds(d) == 90.0
    end

    test "as_minutes" do
      d = Duration.new(%{hours: 1, minutes: 30})
      assert Duration.as_minutes(d) == 90.0
    end

    test "as_hours" do
      d = Duration.new(%{days: 1})
      assert Duration.as_hours(d) == 24.0
    end

    test "as_days" do
      d = Duration.new(%{days: 2, hours: 12})
      assert Duration.as_days(d) == 2.5
    end

    test "as_weeks" do
      d = Duration.new(%{days: 14})
      assert Duration.as_weeks(d) == 2.0
    end
  end

  describe "humanize/1,2" do
    test "humanize seconds" do
      d = Duration.new(30_000)
      assert Duration.humanize(d) == "a few seconds"
    end

    test "humanize minutes" do
      d = Duration.new(%{minutes: 5})
      assert Duration.humanize(d) == "5 minutes"
    end

    test "humanize with suffix" do
      d = Duration.new(%{minutes: 5})
      assert Duration.humanize(d, true) == "in 5 minutes"
    end

    test "humanize hours" do
      d = Duration.new(%{hours: 3})
      assert Duration.humanize(d) == "3 hours"
    end
  end

  describe "to_iso_string/1" do
    test "basic duration" do
      d = Duration.new(%{days: 1, hours: 2, minutes: 30})
      assert Duration.to_iso_string(d) == "P1DT2H30M"
    end

    test "years and months" do
      d = Duration.new(%{years: 1, months: 2})
      assert Duration.to_iso_string(d) == "P1Y2M"
    end

    test "zero duration" do
      d = Duration.new(0)
      assert Duration.to_iso_string(d) == "P0D"
    end
  end

  describe "arithmetic" do
    test "add durations" do
      a = Duration.new(%{hours: 1, minutes: 30})
      b = Duration.new(%{hours: 2, minutes: 45})
      result = Duration.add(a, b)
      assert Duration.hours(result) == 3
      assert Duration.minutes(result) == 75
    end

    test "subtract durations" do
      a = Duration.new(%{hours: 3, minutes: 30})
      b = Duration.new(%{hours: 1, minutes: 15})
      result = Duration.subtract(a, b)
      assert Duration.hours(result) == 2
      assert Duration.minutes(result) == 15
    end
  end
end
