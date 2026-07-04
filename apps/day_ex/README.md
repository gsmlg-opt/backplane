# DayEx

Lightweight Elixir port of [dayjs](https://day.js.org/) — pipe-friendly date/time parsing, formatting, manipulation, and querying.

## Installation

Add `day_ex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:day_ex, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
DayEx.now()
|> DayEx.add(1, :month)
|> DayEx.start_of(:day)
|> DayEx.format("YYYY-MM-DD")
# => "2026-05-09"
```

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

## License

MIT
