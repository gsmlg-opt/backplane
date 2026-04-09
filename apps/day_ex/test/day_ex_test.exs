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

  describe "getters" do
    setup do
      {:ok, dt, _} = DateTime.from_iso8601("2024-03-15T14:30:45.123Z")
      d = %DayEx{datetime: dt}
      %{d: d}
    end

    test "year/1", %{d: d} do
      assert DayEx.year(d) == 2024
    end

    test "month/1 (1-indexed)", %{d: d} do
      assert DayEx.month(d) == 3
    end

    test "date/1 (day of month)", %{d: d} do
      assert DayEx.date(d) == 15
    end

    test "day/1 (day of week, 0=Sunday)", %{d: d} do
      # 2024-03-15 is a Friday = 5
      assert DayEx.day(d) == 5
    end

    test "hour/1", %{d: d} do
      assert DayEx.hour(d) == 14
    end

    test "minute/1", %{d: d} do
      assert DayEx.minute(d) == 30
    end

    test "second/1", %{d: d} do
      assert DayEx.second(d) == 45
    end

    test "millisecond/1", %{d: d} do
      assert DayEx.millisecond(d) == 123
    end
  end

  describe "setters" do
    setup do
      d = DayEx.parse!("2024-03-15T14:30:45Z")
      %{d: d}
    end

    test "year/2", %{d: d} do
      result = DayEx.year(d, 2025)
      assert DayEx.year(result) == 2025
      assert DayEx.month(result) == 3
    end

    test "month/2", %{d: d} do
      result = DayEx.month(d, 6)
      assert DayEx.month(result) == 6
      assert DayEx.year(result) == 2024
    end

    test "date/2", %{d: d} do
      result = DayEx.date(d, 20)
      assert DayEx.date(result) == 20
    end

    test "hour/2", %{d: d} do
      result = DayEx.hour(d, 8)
      assert DayEx.hour(result) == 8
    end

    test "minute/2", %{d: d} do
      result = DayEx.minute(d, 15)
      assert DayEx.minute(result) == 15
    end

    test "second/2", %{d: d} do
      result = DayEx.second(d, 30)
      assert DayEx.second(result) == 30
    end

    test "millisecond/2", %{d: d} do
      result = DayEx.millisecond(d, 500)
      assert DayEx.millisecond(result) == 500
    end

    test "set/3 with :year", %{d: d} do
      result = DayEx.set(d, :year, 2025)
      assert DayEx.year(result) == 2025
    end

    test "set/3 with :month", %{d: d} do
      result = DayEx.set(d, :month, 12)
      assert DayEx.month(result) == 12
    end

    test "immutability — original unchanged", %{d: d} do
      _result = DayEx.year(d, 2025)
      assert DayEx.year(d) == 2024
    end

    test "month overflow — clamps day" do
      # Set month to Feb on a date with day=31
      d = DayEx.parse!("2024-01-31T00:00:00Z")
      result = DayEx.month(d, 2)
      # 2024 is leap year so Feb has 29 days
      assert DayEx.date(result) == 29
    end
  end

  describe "add/3" do
    test "adds days" do
      d = DayEx.parse!("2024-01-15T10:00:00Z")
      result = DayEx.add(d, 5, :day)
      assert DayEx.date(result) == 20
    end

    test "adds months" do
      d = DayEx.parse!("2024-01-31T10:00:00Z")
      result = DayEx.add(d, 1, :month)
      assert DayEx.month(result) == 2
      assert DayEx.date(result) == 29
    end

    test "adds years" do
      d = DayEx.parse!("2024-02-29T10:00:00Z")
      result = DayEx.add(d, 1, :year)
      assert DayEx.year(result) == 2025
      assert DayEx.month(result) == 2
      assert DayEx.date(result) == 28
    end

    test "adds hours" do
      d = DayEx.parse!("2024-01-15T22:00:00Z")
      result = DayEx.add(d, 5, :hour)
      assert DayEx.date(result) == 16
      assert DayEx.hour(result) == 3
    end

    test "adds weeks" do
      d = DayEx.parse!("2024-01-15T10:00:00Z")
      result = DayEx.add(d, 2, :week)
      assert DayEx.date(result) == 29
    end

    test "adds minutes" do
      d = DayEx.parse!("2024-01-15T10:50:00Z")
      result = DayEx.add(d, 20, :minute)
      assert DayEx.hour(result) == 11
      assert DayEx.minute(result) == 10
    end

    test "adds seconds" do
      d = DayEx.parse!("2024-01-15T10:00:50Z")
      result = DayEx.add(d, 20, :second)
      assert DayEx.minute(result) == 1
      assert DayEx.second(result) == 10
    end

    test "adds milliseconds" do
      d = DayEx.parse!("2024-01-15T10:00:00Z")
      result = DayEx.add(d, 1500, :millisecond)
      assert DayEx.second(result) == 1
      assert DayEx.millisecond(result) == 500
    end
  end

  describe "subtract/3" do
    test "subtracts days" do
      d = DayEx.parse!("2024-01-15T10:00:00Z")
      result = DayEx.subtract(d, 5, :day)
      assert DayEx.date(result) == 10
    end

    test "subtracts months across year boundary" do
      d = DayEx.parse!("2024-02-15T10:00:00Z")
      result = DayEx.subtract(d, 3, :month)
      assert DayEx.year(result) == 2023
      assert DayEx.month(result) == 11
    end
  end

  describe "start_of/2" do
    test "start of year" do
      d = DayEx.parse!("2024-06-15T14:30:45Z")
      result = DayEx.start_of(d, :year)
      assert to_string(result) == "2024-01-01T00:00:00Z"
    end

    test "start of month" do
      d = DayEx.parse!("2024-06-15T14:30:45Z")
      result = DayEx.start_of(d, :month)
      assert to_string(result) == "2024-06-01T00:00:00Z"
    end

    test "start of day" do
      d = DayEx.parse!("2024-06-15T14:30:45Z")
      result = DayEx.start_of(d, :day)
      assert to_string(result) == "2024-06-15T00:00:00Z"
    end

    test "start of hour" do
      d = DayEx.parse!("2024-06-15T14:30:45Z")
      result = DayEx.start_of(d, :hour)
      assert to_string(result) == "2024-06-15T14:00:00Z"
    end

    test "start of minute" do
      d = DayEx.parse!("2024-06-15T14:30:45Z")
      result = DayEx.start_of(d, :minute)
      assert to_string(result) == "2024-06-15T14:30:00Z"
    end

    test "start of second" do
      d = DayEx.parse!("2024-06-15T14:30:45.123Z")
      result = DayEx.start_of(d, :second)
      assert DayEx.millisecond(result) == 0
    end

    test "start of week (Sunday)" do
      # 2024-06-15 is Saturday
      d = DayEx.parse!("2024-06-15T14:30:45Z")
      result = DayEx.start_of(d, :week)
      assert DayEx.date(result) == 9
      assert DayEx.hour(result) == 0
    end
  end

  describe "end_of/2" do
    test "end of year" do
      d = DayEx.parse!("2024-06-15T14:30:45Z")
      result = DayEx.end_of(d, :year)
      assert DayEx.month(result) == 12
      assert DayEx.date(result) == 31
      assert DayEx.hour(result) == 23
      assert DayEx.minute(result) == 59
      assert DayEx.second(result) == 59
      assert DayEx.millisecond(result) == 999
    end

    test "end of month" do
      d = DayEx.parse!("2024-02-15T14:30:45Z")
      result = DayEx.end_of(d, :month)
      assert DayEx.date(result) == 29
      assert DayEx.hour(result) == 23
    end

    test "end of day" do
      d = DayEx.parse!("2024-06-15T14:30:45Z")
      result = DayEx.end_of(d, :day)
      assert DayEx.hour(result) == 23
      assert DayEx.minute(result) == 59
      assert DayEx.second(result) == 59
      assert DayEx.millisecond(result) == 999
    end
  end

  describe "valid?/1" do
    test "valid DayEx" do
      assert DayEx.valid?(DayEx.now())
    end

    test "nil datetime is invalid" do
      assert DayEx.valid?(%DayEx{datetime: nil}) == false
    end
  end

  describe "before?/2,3" do
    test "before? without unit" do
      a = DayEx.parse!("2024-01-15T10:00:00Z")
      b = DayEx.parse!("2024-01-15T12:00:00Z")
      assert DayEx.before?(a, b)
      refute DayEx.before?(b, a)
    end

    test "before? with unit" do
      a = DayEx.parse!("2024-01-15T10:00:00Z")
      b = DayEx.parse!("2024-01-15T12:00:00Z")
      refute DayEx.before?(a, b, :day)
      assert DayEx.before?(a, b, :hour)
    end
  end

  describe "after?/2,3" do
    test "after? without unit" do
      a = DayEx.parse!("2024-01-15T12:00:00Z")
      b = DayEx.parse!("2024-01-15T10:00:00Z")
      assert DayEx.after?(a, b)
    end
  end

  describe "same?/2,3" do
    test "same? without unit" do
      a = DayEx.parse!("2024-01-15T10:00:00Z")
      b = DayEx.parse!("2024-01-15T10:00:00Z")
      assert DayEx.same?(a, b)
    end

    test "same? with :day unit" do
      a = DayEx.parse!("2024-01-15T10:00:00Z")
      b = DayEx.parse!("2024-01-15T22:00:00Z")
      assert DayEx.same?(a, b, :day)
      refute DayEx.same?(a, b, :hour)
    end
  end

  describe "same_or_before?/2" do
    test "same or before" do
      a = DayEx.parse!("2024-01-15T10:00:00Z")
      assert DayEx.same_or_before?(a, a)
    end
  end

  describe "same_or_after?/2" do
    test "same or after" do
      a = DayEx.parse!("2024-01-15T12:00:00Z")
      b = DayEx.parse!("2024-01-15T10:00:00Z")
      assert DayEx.same_or_after?(a, b)
    end
  end

  describe "between?/3,4,5" do
    test "between two dates (exclusive)" do
      a = DayEx.parse!("2024-01-10T00:00:00Z")
      b = DayEx.parse!("2024-01-20T00:00:00Z")
      d = DayEx.parse!("2024-01-15T00:00:00Z")
      assert DayEx.between?(d, a, b)
    end

    test "not between when equal to boundary (exclusive)" do
      a = DayEx.parse!("2024-01-10T00:00:00Z")
      b = DayEx.parse!("2024-01-20T00:00:00Z")
      refute DayEx.between?(a, a, b)
    end

    test "between with inclusive '[]'" do
      a = DayEx.parse!("2024-01-10T00:00:00Z")
      b = DayEx.parse!("2024-01-20T00:00:00Z")
      assert DayEx.between?(a, a, b, nil, "[]")
    end

    test "between with '[)'" do
      a = DayEx.parse!("2024-01-10T00:00:00Z")
      b = DayEx.parse!("2024-01-20T00:00:00Z")
      assert DayEx.between?(a, a, b, nil, "[)")
      refute DayEx.between?(b, a, b, nil, "[)")
    end
  end

  describe "diff/2,3,4" do
    test "diff in milliseconds" do
      a = DayEx.parse!("2024-01-15T10:00:00Z")
      b = DayEx.parse!("2024-01-15T12:00:00Z")
      assert DayEx.diff(a, b) == -7_200_000
    end

    test "diff in hours" do
      a = DayEx.parse!("2024-01-15T10:00:00Z")
      b = DayEx.parse!("2024-01-15T12:30:00Z")
      assert DayEx.diff(a, b, :hour) == -2
    end

    test "diff as float" do
      a = DayEx.parse!("2024-01-15T10:00:00Z")
      b = DayEx.parse!("2024-01-15T12:30:00Z")
      assert DayEx.diff(a, b, :hour, float: true) == -2.5
    end

    test "diff in days" do
      a = DayEx.parse!("2024-01-10T00:00:00Z")
      b = DayEx.parse!("2024-01-15T00:00:00Z")
      assert DayEx.diff(a, b, :day) == -5
    end
  end

  describe "leap_year?/1" do
    test "2024 is a leap year" do
      assert DayEx.leap_year?(DayEx.parse!("2024-06-15T00:00:00Z"))
    end

    test "2023 is not a leap year" do
      refute DayEx.leap_year?(DayEx.parse!("2023-06-15T00:00:00Z"))
    end
  end

  describe "utc?/1" do
    test "UTC DateTime is utc" do
      assert DayEx.utc?(DayEx.parse!("2024-01-15T10:00:00Z"))
    end

    test "NaiveDateTime is not utc" do
      refute DayEx.utc?(%DayEx{datetime: ~N[2024-01-15 10:00:00]})
    end
  end

  describe "tz/2 — parse in timezone" do
    test "parse string in timezone" do
      d = DayEx.tz("2024-01-15T10:00:00", "America/New_York")
      assert d.datetime.time_zone == "America/New_York"
    end
  end

  describe "tz/1 — convert to timezone" do
    test "convert UTC to timezone" do
      d = DayEx.parse!("2024-01-15T10:00:00Z")
      result = DayEx.tz(d, "America/New_York")
      assert result.datetime.time_zone == "America/New_York"
      assert DayEx.hour(result) == 5
    end
  end

  describe "tz_name/1" do
    test "returns timezone name" do
      d = DayEx.parse!("2024-01-15T10:00:00Z")
      assert DayEx.tz_name(d) == "Etc/UTC"
    end

    test "returns nil for NaiveDateTime" do
      d = %DayEx{datetime: ~N[2024-01-15 10:00:00]}
      assert DayEx.tz_name(d) == nil
    end
  end

  describe "local/1" do
    test "converts to NaiveDateTime" do
      d = DayEx.parse!("2024-01-15T10:00:00Z")
      result = DayEx.local(d)
      assert %NaiveDateTime{} = result.datetime
    end
  end

  describe "utc_offset/1" do
    test "UTC offset is 0" do
      d = DayEx.parse!("2024-01-15T10:00:00Z")
      assert DayEx.utc_offset(d) == 0
    end

    test "NaiveDateTime offset is nil" do
      d = %DayEx{datetime: ~N[2024-01-15 10:00:00]}
      assert DayEx.utc_offset(d) == nil
    end
  end

  describe "week/1,2" do
    test "week of year" do
      d = DayEx.parse!("2024-01-15T00:00:00Z")
      assert is_integer(DayEx.week(d))
    end

    test "set week" do
      d = DayEx.parse!("2024-01-15T00:00:00Z")
      result = DayEx.week(d, 10)
      assert DayEx.week(result) == 10
    end
  end

  describe "iso_week/1" do
    test "ISO week number" do
      d = DayEx.parse!("2024-01-01T00:00:00Z")
      assert DayEx.iso_week(d) == 1
    end
  end

  describe "day_of_year/1,2" do
    test "day of year" do
      d = DayEx.parse!("2024-02-01T00:00:00Z")
      assert DayEx.day_of_year(d) == 32
    end

    test "set day of year" do
      d = DayEx.parse!("2024-01-01T00:00:00Z")
      result = DayEx.day_of_year(d, 60)
      assert DayEx.month(result) == 2
      assert DayEx.date(result) == 29
    end
  end

  describe "quarter/1,2" do
    test "quarter" do
      d = DayEx.parse!("2024-05-15T00:00:00Z")
      assert DayEx.quarter(d) == 2
    end

    test "set quarter" do
      d = DayEx.parse!("2024-05-15T00:00:00Z")
      result = DayEx.quarter(d, 4)
      assert DayEx.month(result) == 11
    end
  end

  describe "weekday/1" do
    test "locale-aware day of week" do
      d = DayEx.parse!("2024-03-15T00:00:00Z")
      assert DayEx.weekday(d) == 5
    end
  end

  describe "weeks_in_year/1" do
    test "weeks in year" do
      d = DayEx.parse!("2024-01-01T00:00:00Z")
      weeks = DayEx.weeks_in_year(d)
      assert weeks in [52, 53]
    end
  end

  describe "min/1 and max/1" do
    test "min returns earliest" do
      a = DayEx.parse!("2024-01-10T00:00:00Z")
      b = DayEx.parse!("2024-01-15T00:00:00Z")
      c = DayEx.parse!("2024-01-05T00:00:00Z")
      assert DayEx.date(DayEx.min([a, b, c])) == 5
    end

    test "max returns latest" do
      a = DayEx.parse!("2024-01-10T00:00:00Z")
      b = DayEx.parse!("2024-01-15T00:00:00Z")
      c = DayEx.parse!("2024-01-05T00:00:00Z")
      assert DayEx.date(DayEx.max([a, b, c])) == 15
    end
  end

  describe "locale/2" do
    test "set locale" do
      d = DayEx.parse!("2024-01-15T00:00:00Z")
      result = DayEx.locale(d, :fr)
      assert result.locale == :fr
    end
  end
end
