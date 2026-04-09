defmodule DayEx.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "add then subtract returns same date" do
    check all(
            year <- integer(2000..2100),
            month <- integer(1..12),
            day <- integer(1..28),
            hour <- integer(0..23),
            n <- integer(1..100),
            unit <- member_of([:day, :hour, :minute, :second])
          ) do
      ndt = NaiveDateTime.new!(year, month, day, hour, 0, 0)
      d = %DayEx{datetime: ndt}
      result = d |> DayEx.add(n, unit) |> DayEx.subtract(n, unit)
      assert DayEx.year(result) == DayEx.year(d)
      assert DayEx.month(result) == DayEx.month(d)
      assert DayEx.date(result) == DayEx.date(d)
      assert DayEx.hour(result) == DayEx.hour(d)
    end
  end

  property "format then parse round-trips for YYYY-MM-DD" do
    check all(
            year <- integer(2000..2100),
            month <- integer(1..12),
            day <- integer(1..28)
          ) do
      ndt = NaiveDateTime.new!(year, month, day, 0, 0, 0)
      d = %DayEx{datetime: ndt}
      formatted = DayEx.format(d, "YYYY-MM-DD")
      {:ok, parsed} = DayEx.parse(formatted, "YYYY-MM-DD")
      assert DayEx.year(parsed) == year
      assert DayEx.month(parsed) == month
      assert DayEx.date(parsed) == day
    end
  end

  property "format then parse round-trips for YYYY-MM-DD HH:mm:ss" do
    check all(
            year <- integer(2000..2100),
            month <- integer(1..12),
            day <- integer(1..28),
            hour <- integer(0..23),
            minute <- integer(0..59),
            second <- integer(0..59)
          ) do
      ndt = NaiveDateTime.new!(year, month, day, hour, minute, second)
      d = %DayEx{datetime: ndt}
      formatted = DayEx.format(d, "YYYY-MM-DD HH:mm:ss")
      {:ok, parsed} = DayEx.parse(formatted, "YYYY-MM-DD HH:mm:ss")
      assert DayEx.year(parsed) == year
      assert DayEx.month(parsed) == month
      assert DayEx.date(parsed) == day
      assert DayEx.hour(parsed) == hour
      assert DayEx.minute(parsed) == minute
      assert DayEx.second(parsed) == second
    end
  end

  property "comparison is transitive" do
    check all(
            y1 <- integer(2020..2025),
            m1 <- integer(1..12),
            d1 <- integer(1..28),
            y2 <- integer(2020..2025),
            m2 <- integer(1..12),
            d2 <- integer(1..28),
            y3 <- integer(2020..2025),
            m3 <- integer(1..12),
            d3 <- integer(1..28)
          ) do
      a = %DayEx{datetime: NaiveDateTime.new!(y1, m1, d1, 0, 0, 0)}
      b = %DayEx{datetime: NaiveDateTime.new!(y2, m2, d2, 0, 0, 0)}
      c = %DayEx{datetime: NaiveDateTime.new!(y3, m3, d3, 0, 0, 0)}

      if DayEx.before?(a, b) and DayEx.before?(b, c) do
        assert DayEx.before?(a, c)
      end
    end
  end

  property "start_of then end_of contains original" do
    check all(
            year <- integer(2000..2100),
            month <- integer(1..12),
            day <- integer(1..28),
            hour <- integer(0..23),
            unit <- member_of([:year, :month, :day, :hour])
          ) do
      ndt = NaiveDateTime.new!(year, month, day, hour, 30, 0)
      d = %DayEx{datetime: ndt}
      s = DayEx.start_of(d, unit)
      e = DayEx.end_of(d, unit)
      assert DayEx.same_or_after?(d, s)
      assert DayEx.same_or_before?(d, e)
    end
  end

  property "Duration ISO 8601 round-trip" do
    check all(
            years <- integer(0..10),
            months <- integer(0..11),
            days <- integer(0..30),
            hours <- integer(0..23),
            minutes <- integer(0..59),
            seconds <- integer(0..59)
          ) do
      d =
        DayEx.Duration.new(%{
          years: years,
          months: months,
          days: days,
          hours: hours,
          minutes: minutes,
          seconds: seconds
        })

      iso = DayEx.Duration.to_iso_string(d)
      parsed = DayEx.Duration.new(iso)
      assert DayEx.Duration.years(parsed) == years
      assert DayEx.Duration.months(parsed) == months
      assert DayEx.Duration.days(parsed) == days
      assert DayEx.Duration.hours(parsed) == hours
      assert DayEx.Duration.minutes(parsed) == minutes
      assert DayEx.Duration.seconds(parsed) == seconds
    end
  end
end
