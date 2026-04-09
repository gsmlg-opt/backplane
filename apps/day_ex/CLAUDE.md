# day_ex

Elixir port of dayjs. Lightweight date/time library.

## Architecture

- `lib/day_ex.ex` — core struct + all public API
- `lib/day_ex/format.ex` — format token engine
- `lib/day_ex/parse.ex` — custom format string parser
- `lib/day_ex/relative_time.ex` — relative time functions
- `lib/day_ex/locale.ex` — locale behaviour
- `lib/day_ex/locale/en.ex` — English locale (+ zh, ja, ko, es, fr, de)
- `lib/day_ex/duration.ex` — Duration type

## Conventions

- Months are 1-indexed (differs from dayjs 0-indexed)
- All manipulation returns new struct (immutable)
- First arg is always `%DayEx{}` (pipe-friendly)
- Parse functions return `{:ok, t} | {:error, reason}`, bang variants raise
- No global state, no GenServer — pure functions

## Commands

- `mix test apps/day_ex` — run tests
- `mix format apps/day_ex` — format code
- `mix dialyzer` — type checking

## Dependencies

- `tz_data` for timezone support
- `stream_data` (test only) for property tests
