# day_ex — Elixir Port of dayjs

## Overview

`day_ex` is a standalone, Hex-publishable Elixir library that ports the [dayjs](https://day.js.org/) JavaScript API. It provides a lightweight, pipe-friendly API for parsing, manipulating, formatting, and querying dates and times. All dayjs plugin functionality is implemented as first-class functions — no plugin system.

Lives in `apps/day_ex/` within the backplane umbrella but has no umbrella dependencies. Other umbrella apps may depend on it.

## Core Struct

```elixir
defmodule DayEx do
  @type t :: %__MODULE__{
    datetime: DateTime.t() | NaiveDateTime.t(),
    locale: atom()
  }
  defstruct [:datetime, locale: :en]
end
```

- Immutable. All manipulation returns a new `%DayEx{}`.
- Wraps `DateTime.t()` (timezone-aware) or `NaiveDateTime.t()` (naive/local).
- Locale defaults to `:en`.
- `%DayEx{}` is always the first argument (pipe-friendly).

## Dependencies

- `tz_data` — timezone database (runtime)
- `stream_data` — property-based testing (test only)
- No other runtime dependencies.

## Module Structure

| Module | Responsibility |
|---|---|
| `DayEx` | Core struct, constructors, getters/setters, manipulation, comparison, queries, formatting entry point, timezone, week/quarter/calendar, min/max |
| `DayEx.Format` | Recursive descent tokenizer + renderer for dayjs format tokens |
| `DayEx.Parse` | Custom format string parsing (reverse of Format) |
| `DayEx.RelativeTime` | Threshold-based relative time strings (from_now, to_now, from, to) |
| `DayEx.Duration` | Duration struct with decomposed fields, arithmetic, humanize, ISO 8601 |
| `DayEx.Locale` | Behaviour defining locale contract |
| `DayEx.Locale.En` | English locale (default) |
| `DayEx.Locale.Zh` | Chinese locale |
| `DayEx.Locale.Ja` | Japanese locale |
| `DayEx.Locale.Ko` | Korean locale |
| `DayEx.Locale.Es` | Spanish locale |
| `DayEx.Locale.Fr` | French locale |
| `DayEx.Locale.De` | German locale |

## Design Decisions

1. **Months are 1-indexed** — Elixir convention. Only intentional deviation from dayjs (which uses 0-indexed months).
2. **Parse returns `{:ok, t} | {:error, reason}`** — bang variants `parse!/1,2,3` raise `ArgumentError`.
3. **Recursive descent tokenizer** — parses format string left-to-right, greedily matches longest token first. Handles `[escaped]` literals. Zero external deps.
4. **Locale as behaviour** — each locale module implements callbacks. Resolved at runtime via `Module.concat(DayEx.Locale, locale_atom)`.
5. **Protocols**: `String.Chars` (interpolation), `Inspect` (readable `#DayEx<2024-01-15T10:30:00Z en>`), `Compare` for `Enum.sort/1`.
6. **Duration stores decomposed fields** — `%{years: 0, months: 0, days: 0, hours: 0, minutes: 0, seconds: 0, milliseconds: 0}` preserves "1 month" vs "30 days" for accurate humanize and ISO 8601 round-trips.
7. **Timezone via tz_data** — uses Elixir's `DateTime.shift_zone/2`. `utc/0,1` creates UTC `DateTime`. `tz/2` parses into specific timezone. `local/1` converts to `NaiveDateTime`.
8. **No GenServer / process state** — pure functional. No global locale config.
9. **Total duration conversions** use dayjs approximations: 1 month = 30.44 days, 1 year = 365.25 days.

## API Surface

### Constructors / Parsing

- `now/0,1` — current time (UTC, optionally with locale)
- `parse/1` — from ISO 8601 string, unix timestamp, DateTime, NaiveDateTime, Date, `%DayEx{}`
- `parse/2,3` — with custom format string and optional locale
- `parse!/1,2,3` — bang variants
- `unix/1` — from unix timestamp (seconds)
- `utc/0,1` — current/parsed as explicit UTC

### Getters / Setters

- `year/1,2`, `month/1,2`, `date/1,2`, `day/1`, `hour/1,2`, `minute/1,2`, `second/1,2`, `millisecond/1,2`
- `set/3` — generic setter by unit atom

### Manipulation

- `add/3`, `subtract/3` — units: `:year`, `:month`, `:week`, `:day`, `:hour`, `:minute`, `:second`, `:millisecond`
- `start_of/2`, `end_of/2` — truncate to start/end of unit

### Formatting

- `format/1` — ISO 8601 default
- `format/2` — dayjs token string (full token set including advancedFormat, isoWeek tokens)
- `to_iso_string/1`, `to_string/1`, `to_json/1`, `to_unix/1`, `to_list/1`, `to_map/1`, `to_date/1`

### Format Tokens

Full dayjs token set: `YY`, `YYYY`, `M`, `MM`, `MMM`, `MMMM`, `D`, `DD`, `d`, `dd`, `ddd`, `dddd`, `H`, `HH`, `h`, `hh`, `m`, `mm`, `s`, `ss`, `SSS`, `Z`, `ZZ`, `A`, `a`, `X`, `x`, `Q`, `Do`, `k`, `kk`, `GGGG`, `GG`, `wo`, `w`, `ww`, `W`, `WW`. Escape with `[text]`.

### Comparison / Query

- `before?/2,3`, `after?/2,3`, `same?/2,3` — with optional unit granularity
- `same_or_before?/2,3`, `same_or_after?/2,3`
- `between?/3,4,5` — with inclusivity strings `"()"`, `"[]"`, `"[)"`, `"(]"`
- `diff/2,3,4` — difference in milliseconds or unit, optionally as float
- `leap_year?/1`, `valid?/1`, `utc?/1`

### Relative Time

- `from_now/1,2`, `to_now/1,2`, `from/2,3`, `to/2,3`
- Thresholds match dayjs defaults (0-44s → "a few seconds ago", etc.)

### Timezone

- `tz/1,2` — convert to / parse in timezone
- `tz_name/1` — get timezone name
- `local/1` — convert to naive (strip timezone)
- `utc_offset/1` — offset in minutes

### Week / Quarter / Calendar

- `week/1,2`, `iso_week/1,2`, `week_year/1`, `iso_week_year/1`
- `day_of_year/1,2`, `quarter/1,2`, `weekday/1,2`, `weeks_in_year/1`

### Min / Max

- `min/1`, `max/1` — earliest/latest from list

### Duration

- `DayEx.Duration.new/1` — from milliseconds, map, or ISO 8601 string
- Getters: `milliseconds/1`, `seconds/1`, `minutes/1`, `hours/1`, `days/1`, `months/1`, `years/1`
- Totals: `as_milliseconds/1`, `as_seconds/1`, `as_minutes/1`, `as_hours/1`, `as_days/1`, `as_weeks/1`, `as_months/1`, `as_years/1`
- `humanize/1,2`, `to_iso_string/1`, `add/2`, `subtract/2`

### Locale

- `locale/2` — set locale on instance
- Shipped locales: `:en`, `:zh`, `:ja`, `:ko`, `:es`, `:fr`, `:de`
- Locale behaviour provides: month names, day names, relative time strings, ordinal function, week start day, AM/PM strings

## File Structure

```
apps/day_ex/
├── lib/
│   ├── day_ex.ex
│   └── day_ex/
│       ├── format.ex
│       ├── parse.ex
│       ├── relative_time.ex
│       ├── duration.ex
│       ├── locale.ex
│       └── locale/
│           ├── en.ex
│           ├── zh.ex
│           ├── ja.ex
│           ├── ko.ex
│           ├── es.ex
│           ├── fr.ex
│           └── de.ex
├── test/
│   ├── test_helper.exs
│   ├── day_ex_test.exs
│   └── day_ex/
│       ├── format_test.exs
│       ├── parse_test.exs
│       ├── relative_time_test.exs
│       ├── duration_test.exs
│       └── locale_test.exs
│   └── property_test.exs
├── mix.exs
├── CLAUDE.md
└── README.md
```

## Testing Strategy

- Unit tests for every public function
- Property-based tests (StreamData): parse/format round-trips, add/subtract inverses, comparison transitivity
- Edge cases: leap years, DST transitions, month boundaries, year boundaries
- Locale-specific formatting tests
- Duration parsing/formatting round-trips

## Implementation Phases

1. **Core**: Scaffold, struct, protocols, parse/1, getters, setters, add/subtract, start_of/end_of, valid?
2. **Formatting & Parsing**: Token parser, format/2, parse/2, to_* converters
3. **Comparison & Query**: before?/after?/same?, between?, diff, leap_year?
4. **Time Features**: Locale infrastructure + En, relative time, min/max, week/quarter/calendar, timezone
5. **Duration**: Struct, constructors, getters, as_* totals, humanize, ISO 8601, arithmetic
6. **Polish**: Typespecs, docs, additional locales (zh, ja, ko, es, fr, de), property tests
