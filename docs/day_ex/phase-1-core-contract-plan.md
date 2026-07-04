# DayEx Phase 1 Core Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking; checked items reflect work completed in this branch.

**Goal:** Harden the first DayEx Phase 1 core contract slice by adding map/list constructors, native conversion helpers, unit aliases, quarter unit support, and explicit Duration validity checks.

**Architecture:** Keep DayEx as a pure-function library with `%DayEx{}` as the user-facing value. Add parsing and unit normalization inside `DayEx` because this slice extends existing public entry points, not a new runtime subsystem. Add `DayEx.Duration.valid?/1` in `DayEx.Duration` because duration validity belongs with duration data.

**Tech Stack:** Elixir 1.18+, ExUnit, StreamData property tests, `tzdata` through existing DateTime timezone support.

---

## Scope

This plan implements only the first Phase 1 slice from `docs/day_ex/PRD.md`.

Included:

- `DayEx.parse/1` support for maps with atom or string keys.
- `DayEx.parse/1` support for lists shaped as `[year, month]` through `[year, month, date, hour, minute, second, millisecond]`.
- `DayEx.to_datetime/1`, `DayEx.to_naive_datetime/1`, and `DayEx.to_unix_millisecond/1`.
- Unit aliases for `set/3`, `add/3`, `subtract/3`, `start_of/2`, `end_of/2`, `diff/3`, `diff/4`, and unit-granularity query helpers.
- `:quarter` support for `add/3`, `subtract/3`, `start_of/2`, `end_of/2`, `diff/3`, and `diff/4`.
- `DayEx.Duration.valid?/1`.
- README examples for new constructors and conversions.

Not included:

- Full localized format token parity.
- Timezone default guessing.
- Locale customization.
- Backplane managed `day::` service expansion.
- New process, registry, plugin, or global state behavior.

## File Structure

- Modify `apps/day_ex/lib/day_ex.ex`: add map/list parsing helpers, unit normalization, quarter unit behavior, and conversion helpers.
- Modify `apps/day_ex/lib/day_ex/duration.ex`: add `valid?/1`.
- Modify `apps/day_ex/test/day_ex_test.exs`: add public API tests for constructors, conversions, unit aliases, and quarter behavior.
- Modify `apps/day_ex/test/day_ex/duration_test.exs`: add duration validity tests.
- Modify `apps/day_ex/README.md`: document new Phase 1 core-contract examples.

## Verification Commands

- Baseline and final scoped test command:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix test'
```

- Focused DayEx public API test command:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix test test/day_ex_test.exs'
```

- Focused duration test command:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix test test/day_ex/duration_test.exs'
```

- Formatting check:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix format --check-formatted'
```

## Task 1: Add Failing Core Contract Tests

**Files:**

- Modify `apps/day_ex/test/day_ex_test.exs`
- Modify `apps/day_ex/test/day_ex/duration_test.exs`

- [x] **Step 1: Add map and list constructor tests**

Append these tests to `describe "parse/1"` in `apps/day_ex/test/day_ex_test.exs`:

```elixir
test "parses map constructor with atom keys" do
  assert {:ok, %DayEx{datetime: dt, locale: :fr}} =
           DayEx.parse(%{
             year: 2024,
             month: 3,
             date: 15,
             hour: 14,
             minute: 30,
             second: 45,
             millisecond: 123,
             locale: :fr
           })

  assert %NaiveDateTime{} = dt
  assert dt == ~N[2024-03-15 14:30:45.123]
end

test "parses map constructor with string keys and timezone" do
  assert {:ok, %DayEx{datetime: dt}} =
           DayEx.parse(%{
             "year" => 2024,
             "month" => 3,
             "date" => 15,
             "hour" => 10,
             "time_zone" => "America/New_York"
           })

  assert %DateTime{} = dt
  assert dt.time_zone == "America/New_York"
  assert DayEx.format(%DayEx{datetime: dt}, "YYYY-MM-DD HH:mm Z") == "2024-03-15 10:00 -04:00"
end

test "parses list constructor fields" do
  assert {:ok, d} = DayEx.parse([2024, 3, 15, 14, 30, 45, 123])
  assert d.datetime == ~N[2024-03-15 14:30:45.123]
end

test "returns error for invalid map constructor fields" do
  assert {:error, "invalid date/time fields: :invalid_date"} =
           DayEx.parse(%{year: 2024, month: 2, date: 31})
end

test "returns error for invalid list constructor arity" do
  assert {:error, "expected list constructor with 2 to 7 values"} = DayEx.parse([2024])
end
```

- [x] **Step 2: Add conversion helper tests**

Append this new describe block to `apps/day_ex/test/day_ex_test.exs` near the existing conversion tests:

```elixir
describe "conversion helpers" do
  test "to_datetime/1 returns DateTime values unchanged" do
    d = DayEx.parse!("2024-01-15T10:30:00Z")
    assert DayEx.to_datetime(d) == ~U[2024-01-15 10:30:00Z]
  end

  test "to_datetime/1 treats NaiveDateTime values as UTC" do
    d = DayEx.parse!("2024-01-15T10:30:00")
    assert DayEx.to_datetime(d) == ~U[2024-01-15 10:30:00Z]
  end

  test "to_naive_datetime/1 strips timezone from DateTime values" do
    d = DayEx.parse!("2024-01-15T10:30:00Z")
    assert DayEx.to_naive_datetime(d) == ~N[2024-01-15 10:30:00]
  end

  test "to_unix_millisecond/1 returns unix milliseconds" do
    d = DayEx.parse!("1970-01-01T00:00:01.123Z")
    assert DayEx.to_unix_millisecond(d) == 1123
  end
end
```

- [x] **Step 3: Add unit alias and quarter tests**

Append this describe block to `apps/day_ex/test/day_ex_test.exs` after the existing `add/3`, `start_of/2`, `end_of/2`, and `diff/2,3,4` coverage:

```elixir
describe "unit aliases" do
  test "add/3 accepts plural and short unit aliases" do
    d = DayEx.parse!("2024-01-15T10:00:00Z")

    assert DayEx.date(DayEx.add(d, 2, :days)) == 17
    assert DayEx.hour(DayEx.add(d, 2, "h")) == 12
    assert DayEx.minute(DayEx.add(d, 15, "minutes")) == 15
  end

  test "set/3 accepts plural aliases" do
    d = DayEx.parse!("2024-01-15T10:00:00Z")

    assert DayEx.year(DayEx.set(d, :years, 2025)) == 2025
    assert DayEx.date(DayEx.set(d, "dates", 20)) == 20
  end

  test "query helpers accept unit aliases" do
    a = DayEx.parse!("2024-01-15T10:00:00Z")
    b = DayEx.parse!("2024-01-15T22:00:00Z")

    assert DayEx.same?(a, b, "day")
    refute DayEx.same?(a, b, :hours)
    assert DayEx.before?(a, b, "h")
  end
end

describe "quarter unit" do
  test "add/3 adds calendar quarters" do
    d = DayEx.parse!("2024-01-31T10:00:00Z")
    result = DayEx.add(d, 1, :quarter)

    assert DayEx.month(result) == 4
    assert DayEx.date(result) == 30
  end

  test "start_of/2 and end_of/2 support quarter aliases" do
    d = DayEx.parse!("2024-05-15T14:30:45Z")

    assert DayEx.format(DayEx.start_of(d, "quarter"), "YYYY-MM-DD HH:mm:ss") ==
             "2024-04-01 00:00:00"

    assert DayEx.format(DayEx.end_of(d, :quarters), "YYYY-MM-DD HH:mm:ss.SSS") ==
             "2024-06-30 23:59:59.999"
  end

  test "diff/3 supports quarter aliases" do
    start = DayEx.parse!("2024-01-01T00:00:00Z")
    finish = DayEx.parse!("2024-07-01T00:00:00Z")

    assert DayEx.diff(finish, start, :quarter) == 2
    assert DayEx.diff(finish, start, "quarters", float: true) == 2.0
  end
end
```

- [x] **Step 4: Add duration validity tests**

Append this describe block to `apps/day_ex/test/day_ex/duration_test.exs`:

```elixir
describe "valid?/1" do
  test "returns true for a duration with integer fields" do
    assert Duration.valid?(Duration.new(%{years: 1, months: 2, milliseconds: 3}))
  end

  test "returns false for structs with non-integer fields" do
    refute Duration.valid?(%Duration{seconds: 1.5})
  end

  test "returns false for non-duration values" do
    refute Duration.valid?(%{})
    refute Duration.valid?(nil)
  end
end
```

- [x] **Step 5: Run tests and verify RED**

Run:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix test test/day_ex_test.exs test/day_ex/duration_test.exs'
```

Expected result: tests fail because map/list constructors, conversion helpers, unit aliases, quarter unit behavior, and `Duration.valid?/1` are not implemented yet.

## Task 2: Implement Constructors And Conversion Helpers

**Files:**

- Modify `apps/day_ex/lib/day_ex.ex`

- [x] **Step 1: Add parse clauses before the binary parse clause**

Add these clauses after `parse(%Date{} = date)` and before numeric parse clauses:

```elixir
def parse(fields) when is_map(fields), do: parse_map(fields)
def parse(fields) when is_list(fields), do: parse_list(fields)
```

- [x] **Step 2: Add public conversion helpers near existing `to_*` functions**

Add:

```elixir
def to_datetime(%DayEx{datetime: %DateTime{} = dt}), do: dt

def to_datetime(%DayEx{datetime: %NaiveDateTime{} = ndt}),
  do: DateTime.from_naive!(ndt, "Etc/UTC")

def to_naive_datetime(%DayEx{datetime: %DateTime{} = dt}), do: DateTime.to_naive(dt)
def to_naive_datetime(%DayEx{datetime: %NaiveDateTime{} = ndt}), do: ndt

def to_unix_millisecond(%DayEx{datetime: %DateTime{} = dt}),
  do: DateTime.to_unix(dt, :millisecond)

def to_unix_millisecond(%DayEx{datetime: %NaiveDateTime{} = ndt}),
  do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
```

- [x] **Step 3: Add map/list private helpers near other private helpers**

Use helper functions with explicit errors:

```elixir
defp parse_map(fields) do
  locale = map_get(fields, :locale, :en)
  timezone = map_get(fields, :time_zone, nil) || map_get(fields, :timezone, nil)

  with {:ok, ndt} <- build_naive_datetime(fields) do
    if is_binary(timezone) do
      case DateTime.from_naive(ndt, timezone) do
        {:ok, dt} -> {:ok, %DayEx{datetime: dt, locale: locale}}
        {:ambiguous, first, _second} -> {:ok, %DayEx{datetime: first, locale: locale}}
        {:gap, _before, after_gap} -> {:ok, %DayEx{datetime: after_gap, locale: locale}}
        {:error, reason} -> {:error, "invalid timezone: #{inspect(reason)}"}
      end
    else
      {:ok, %DayEx{datetime: ndt, locale: locale}}
    end
  end
end

defp parse_list(fields) when length(fields) in 2..7 do
  keys = [:year, :month, :date, :hour, :minute, :second, :millisecond]

  fields
  |> Enum.zip(keys)
  |> Map.new(fn {value, key} -> {key, value} end)
  |> parse_map()
end

defp parse_list(_fields), do: {:error, "expected list constructor with 2 to 7 values"}
```

Add these helpers after `parse_list/1`:

```elixir
defp build_naive_datetime(fields) do
  year = map_get(fields, :year, 2000)
  month = map_get(fields, :month, 1)
  day = map_get(fields, :date, nil) || map_get(fields, :day, 1)
  hour = map_get(fields, :hour, 0)
  minute = map_get(fields, :minute, 0)
  second = map_get(fields, :second, 0)
  millisecond = map_get(fields, :millisecond, 0)

  with true <- Enum.all?([year, month, day, hour, minute, second, millisecond], &is_integer/1),
       {:ok, ndt} <- NaiveDateTime.new(year, month, day, hour, minute, second, {millisecond * 1000, 3}) do
    {:ok, ndt}
  else
    false -> {:error, "invalid date/time fields: :invalid_field"}
    {:error, reason} -> {:error, "invalid date/time fields: #{inspect(reason)}"}
  end
end

defp map_get(map, key, default) do
  Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
```

- [x] **Step 4: Run focused tests**

Run:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix test test/day_ex_test.exs'
```

Expected result: constructor and conversion tests pass; unit alias and quarter tests still fail until Task 3.

## Task 3: Implement Unit Aliases And Quarter Unit

**Files:**

- Modify `apps/day_ex/lib/day_ex.ex`

- [x] **Step 1: Normalize units at public entry points**

Update public functions that accept units so they call `normalize_unit/1` once and delegate to private normalized helpers:

```elixir
def set(d, unit, value), do: do_set(d, normalize_unit(unit), value)
def add(%DayEx{} = d, n, unit), do: do_add(d, n, normalize_unit(unit))
def subtract(%DayEx{} = d, n, unit), do: add(d, -n, unit)
def start_of(%DayEx{} = d, unit), do: do_start_of(d, normalize_unit(unit))
def end_of(%DayEx{} = d, unit), do: do_end_of(d, normalize_unit(unit))
```

For comparisons and diffs, normalize the unit before using `start_of/2`, `unit_to_ms/1`, or calendar diff helpers.

- [x] **Step 2: Add normalized implementation helpers**

Move existing unit-specific logic behind `do_set/3`, `do_add/3`, `do_start_of/2`, and `do_end_of/2`. Add quarter behavior:

```elixir
defp do_add(%DayEx{} = d, n, :quarter), do: do_add(d, n * 3, :month)

defp do_start_of(%DayEx{} = d, :quarter) do
  quarter_start_month = (quarter(d) - 1) * 3 + 1

  d
  |> month(quarter_start_month)
  |> date(1)
  |> do_start_of(:day)
end

defp do_end_of(%DayEx{} = d, :quarter) do
  d
  |> do_start_of(:quarter)
  |> do_add(3, :month)
  |> do_add(-1, :millisecond)
end
```

For `diff/3`, quarter diff is `trunc(calendar_month_diff(a, b) / 3)`. For float diff, quarter diff is `calendar_month_diff_float(a, b) / 3`.

- [x] **Step 3: Add `normalize_unit/1` aliases**

Add aliases for atoms and binaries:

```elixir
defp normalize_unit(unit) when unit in [:year, :years, :y] or unit in ["year", "years", "y"], do: :year
defp normalize_unit(unit) when unit in [:quarter, :quarters, :Q] or unit in ["quarter", "quarters", "Q"], do: :quarter
defp normalize_unit(unit) when unit in [:month, :months, :M] or unit in ["month", "months", "M"], do: :month
defp normalize_unit(unit) when unit in [:week, :weeks, :w] or unit in ["week", "weeks", "w"], do: :week
defp normalize_unit(unit) when unit in [:day, :days, :d] or unit in ["day", "days", "d"], do: :day
defp normalize_unit(unit) when unit in [:date, :dates, :D] or unit in ["date", "dates", "D"], do: :date
defp normalize_unit(unit) when unit in [:hour, :hours, :h] or unit in ["hour", "hours", "h"], do: :hour
defp normalize_unit(unit) when unit in [:minute, :minutes, :m] or unit in ["minute", "minutes", "m"], do: :minute
defp normalize_unit(unit) when unit in [:second, :seconds, :s] or unit in ["second", "seconds", "s"], do: :second
defp normalize_unit(unit) when unit in [:millisecond, :milliseconds, :ms] or unit in ["millisecond", "milliseconds", "ms"], do: :millisecond
```

Keep unsupported unit behavior explicit by raising `ArgumentError` with `unsupported unit: #{inspect(unit)}`.

- [x] **Step 4: Run focused tests**

Run:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix test test/day_ex_test.exs'
```

Expected result: all `DayExTest` tests pass.

## Task 4: Implement Duration Validity

**Files:**

- Modify `apps/day_ex/lib/day_ex/duration.ex`

- [x] **Step 1: Add `valid?/1` near getters**

Add:

```elixir
@spec valid?(term()) :: boolean()
def valid?(%__MODULE__{} = duration) do
  Enum.all?(
    [
      duration.years,
      duration.months,
      duration.days,
      duration.hours,
      duration.minutes,
      duration.seconds,
      duration.milliseconds
    ],
    &is_integer/1
  )
end

def valid?(_), do: false
```

- [x] **Step 2: Run focused duration tests**

Run:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix test test/day_ex/duration_test.exs'
```

Expected result: all duration tests pass.

## Task 5: Document New Core Contract Examples

**Files:**

- Modify `apps/day_ex/README.md`

- [x] **Step 1: Add constructor and conversion examples after Quick Start**

Add:

````markdown
## Constructors

```elixir
DayEx.parse(%{year: 2024, month: 3, date: 15, hour: 10})
DayEx.parse([2024, 3, 15, 10, 30])
DayEx.parse(%{"year" => 2024, "month" => 3, "date" => 15, "time_zone" => "America/New_York"})
```

Map and list constructors use DayEx's Elixir-facing convention: months are 1-indexed.

## Conversions

```elixir
d = DayEx.parse!("2024-01-15T10:30:00Z")

DayEx.to_datetime(d)
DayEx.to_naive_datetime(d)
DayEx.to_unix(d)
DayEx.to_unix_millisecond(d)
DayEx.to_map(d)
DayEx.to_list(d)
DayEx.to_date(d)
```
````

- [x] **Step 2: Run format check**

Run:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix format --check-formatted'
```

Expected result: formatting check passes.

## Task 6: Final Verification And Commit

**Files:**

- Verify all touched files.

- [x] **Step 1: Run scoped full DayEx tests**

Run:

```bash
devenv shell -- bash -lc 'cd apps/day_ex && mix test'
```

Expected result: all DayEx tests pass.

- [x] **Step 2: Run diff whitespace check**

Run:

```bash
git diff --check
```

Expected result: no output and exit code 0.

- [x] **Step 3: Review changed files**

Run:

```bash
git diff --stat
git diff -- apps/day_ex/lib/day_ex.ex apps/day_ex/lib/day_ex/duration.ex apps/day_ex/test/day_ex_test.exs apps/day_ex/test/day_ex/duration_test.exs apps/day_ex/README.md docs/day_ex/phase-1-core-contract-plan.md
```

Expected result: only the files in this plan changed.

- [x] **Step 4: Commit**

Run:

```bash
git add docs/day_ex/phase-1-core-contract-plan.md apps/day_ex/lib/day_ex.ex apps/day_ex/lib/day_ex/duration.ex apps/day_ex/test/day_ex_test.exs apps/day_ex/test/day_ex/duration_test.exs apps/day_ex/README.md
git commit -m "feat(day_ex): harden core constructor contract"
```
