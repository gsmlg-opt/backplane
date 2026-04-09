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

## License

MIT
