# DayEx Day.js Parity PRD

Status: Draft
Scope: DayEx roadmap and requirements
Primary app: `day_ex`

## Problem Statement

`day_ex` is intended to be an Elixir implementation of Day.js, but the current library is still at the first broad step: it has a useful immutable `%DayEx{}` struct, parsing, formatting, manipulation, relative time, duration, locale, timezone, and query foundations, but it does not yet have a complete product-level roadmap for Day.js parity.

Day.js splits much of its functionality into plugins. That model does not fit this Elixir library. DayEx should not have a plugin registry, extension macro, global mutable plugin loading step, or opt-in runtime feature system. The useful capability behind those Day.js plugins should become standard DayEx modules and public APIs that are always available when the library is installed.

The main user problem is uncertainty: contributors need to know which Day.js behaviors DayEx intends to support, which JavaScript details are intentionally different in Elixir, what order to build features in, and how to verify compatibility without turning DayEx into a JavaScript-style plugin platform.

## Solution

Build DayEx as a standalone, Hex-publishable Elixir date/time library with Day.js-like behavior and Elixir-native ergonomics.

DayEx will expose one pipe-friendly core API on `%DayEx{}` plus normal standard modules for feature areas:

- `DayEx` for constructors, getters, setters, manipulation, comparison, conversion, and convenience entry points.
- `DayEx.Parse` for string, token, object, array, Unix, UTC, timezone-aware, strict, and localized parsing.
- `DayEx.Format` for Day.js token rendering, localized tokens, advanced tokens, escaping, and locale-aware output.
- `DayEx.Duration` for duration construction, arithmetic, total conversions, formatting, ISO 8601, and humanization.
- `DayEx.RelativeTime` for `from`, `to`, `from_now`, `to_now`, and threshold-based human output.
- `DayEx.Locale` and locale modules for locale data, localized formats, ordinals, meridiem, week starts, relative time, and safe locale customization.
- `DayEx.Calendar` for calendar-specific features such as day of year, quarter, week, ISO week, week year, Buddhist era, calendar time, today, tomorrow, and yesterday.
- `DayEx.Query` for query helpers such as before, after, same, between, same-or-before, same-or-after, leap year, min, and max.
- `DayEx.Timezone` for UTC, local, timezone conversion, parsing in zone, offsets, zone names, and timezone guessing where possible.
- `DayEx.Compatibility` for optional test-support helpers that compare DayEx behavior against captured Day.js fixtures. This is not a runtime plugin system.

Compatibility is defined as matching Day.js behavior where it is meaningful for Elixir users, while preserving Elixir conventions:

- Months stay 1-indexed in DayEx.
- APIs are pipe-friendly and take `%DayEx{}` as the first argument when operating on an instance.
- Expected failures return `{:ok, value}` or `{:error, reason}`; bang variants raise.
- All values are immutable.
- There is no global plugin loading, no mutable default plugin state, and no GenServer for stateless date/time operations.
- Global mutable locale or timezone defaults are avoided. Prefer explicit arguments and values stored on `%DayEx{}`.

## User Stories

1. As an Elixir developer, I want DayEx to parse common date/time inputs, so that I can normalize inputs without reaching for JavaScript.
2. As an Elixir developer, I want DayEx to parse ISO 8601 strings, so that API timestamps work out of the box.
3. As an Elixir developer, I want DayEx to parse Unix seconds and milliseconds, so that storage and API timestamp formats are easy to consume.
4. As an Elixir developer, I want DayEx to parse custom format strings, so that legacy and user-entered date formats can be supported.
5. As an Elixir developer, I want strict parsing to reject trailing input and impossible dates, so that invalid user input does not silently pass.
6. As an Elixir developer, I want parsing errors as data, so that I can show validation messages without rescuing exceptions.
7. As an Elixir developer, I want bang parsing variants, so that tests and trusted paths can fail fast.
8. As an Elixir developer, I want object-like and array-like input support, so that Day.js object and array support maps to Elixir maps and lists.
9. As an Elixir developer, I want a single DayEx struct, so that date/time values have a consistent shape across the library.
10. As an Elixir developer, I want immutable manipulation, so that date/time transformations are safe in pipelines.
11. As an Elixir developer, I want add and subtract for all Day.js units, so that scheduling logic can be expressed clearly.
12. As an Elixir developer, I want month and year arithmetic to clamp correctly, so that month-end dates behave predictably.
13. As an Elixir developer, I want timezone-aware day arithmetic to respect calendar days, so that DST boundaries do not shift wall-clock intent.
14. As an Elixir developer, I want start-of and end-of helpers for all supported units, so that reporting boundaries are easy to compute.
15. As an Elixir developer, I want getters and setters for date parts, so that I can inspect and transform values without manual struct access.
16. As an Elixir developer, I want plural and singular unit aliases, so that the API is forgiving where Day.js is forgiving.
17. As an Elixir developer, I want Day.js-compatible format tokens, so that existing format strings can move to Elixir.
18. As an Elixir developer, I want localized format tokens, so that display output matches local expectations.
19. As an Elixir developer, I want advanced format tokens as standard DayEx features, so that no opt-in extension step is required.
20. As an Elixir developer, I want escaped literals in format strings, so that labels and punctuation render correctly.
21. As an Elixir developer, I want locale-aware month and weekday names, so that user-facing output can be translated.
22. As an Elixir developer, I want locale-aware ordinals and meridiem strings, so that formatted output reads naturally.
23. As an Elixir developer, I want relative time strings, so that activity and audit timestamps can be shown as human text.
24. As an Elixir developer, I want relative time without suffixes, so that I can compose labels myself.
25. As an Elixir developer, I want calendar time output, so that dates near today can be shown as "today", "tomorrow", or nearby weekdays.
26. As an Elixir developer, I want today, tomorrow, and yesterday predicates, so that common date filters are simple.
27. As an Elixir developer, I want before, after, same, same-or-before, and same-or-after queries, so that comparisons are readable.
28. As an Elixir developer, I want unit-granularity comparisons, so that I can compare by day, month, year, or other units.
29. As an Elixir developer, I want between queries with inclusivity options, so that range checks match Day.js behavior.
30. As an Elixir developer, I want min and max helpers, so that I can find earliest and latest DayEx values from collections.
31. As an Elixir developer, I want leap-year checks, so that calendar rules do not need to be reimplemented in application code.
32. As an Elixir developer, I want day-of-year, quarter, week, ISO week, week year, and ISO week year helpers, so that reporting calendars are covered.
33. As an Elixir developer, I want locale-aware weekday helpers, so that calendars can start on the correct day for the locale.
34. As an Elixir developer, I want weeks-in-year helpers, so that ISO calendar reporting is accurate.
35. As an Elixir developer, I want UTC constructors and conversion helpers, so that timestamp normalization is explicit.
36. As an Elixir developer, I want timezone parsing and conversion, so that user-local dates can be handled correctly.
37. As an Elixir developer, I want UTC offset helpers, so that serialized output can include correct offsets.
38. As an Elixir developer, I want parsing in a named timezone, so that naive user input can be interpreted in the right zone.
39. As an Elixir developer, I want clear behavior for ambiguous and gap local times, so that DST edge cases are predictable.
40. As an Elixir developer, I want duration construction from milliseconds, maps, and ISO 8601, so that time spans can be modeled directly.
41. As an Elixir developer, I want duration getters and total conversions, so that reporting and arithmetic can use the right unit.
42. As an Elixir developer, I want duration add and subtract, so that time spans can be combined without manual field math.
43. As an Elixir developer, I want duration formatting and ISO output, so that durations can be displayed and serialized.
44. As an Elixir developer, I want duration humanization, so that elapsed time can be rendered for users.
45. As an Elixir developer, I want duration values to work with DayEx diff results, so that elapsed time calculations compose naturally.
46. As an Elixir developer, I want locale data access, so that applications can list localized months, weekdays, and formats.
47. As an Elixir developer, I want safe locale customization, so that an application can override text without changing global library state.
48. As an Elixir developer, I want pre-parse and post-format hooks as explicit locale features, so that locale-specific digits or calendars can be supported without plugins.
49. As an Elixir developer, I want Buddhist era formatting as a standard calendar feature, so that Day.js BuddhistEra behavior is available without plugins.
50. As an Elixir developer, I want conversion to ISO strings, JSON strings, maps, lists, dates, and native Elixir date/time structs, so that DayEx can interoperate with Ecto, Phoenix, and API layers.
51. As an Elixir developer, I want inspection and string conversion to be predictable, so that logs and debugging output are useful.
52. As a Backplane maintainer, I want the managed `day::` service to use DayEx capabilities directly, so that MCP tools expose the same behavior as the library.
53. As a Backplane maintainer, I want DayEx to stay independent of umbrella app internals, so that it can be published or reused separately.
54. As a contributor, I want a clear roadmap, so that I can choose the next implementation task without guessing priorities.
55. As a contributor, I want compatibility fixtures, so that changes can be validated against Day.js behavior.
56. As a contributor, I want property tests around arithmetic and formatting, so that edge cases are caught early.
57. As a contributor, I want focused module boundaries, so that a feature can be implemented without editing one large catch-all module every time.
58. As a contributor, I want no plugin system, so that the library remains simple, static, and easy to reason about.
59. As a contributor, I want standard modules for former plugin capabilities, so that feature ownership is visible in the codebase.
60. As a maintainer, I want documented intentional differences from Day.js, so that compatibility reports can distinguish bugs from design choices.

## Product Requirements

### Core API

- DayEx must keep a single immutable `%DayEx{}` value as the primary user-facing date/time type.
- Public instance functions should remain pipe-friendly.
- Constructors must support current time, native `DateTime`, native `NaiveDateTime`, native `Date`, Unix seconds, Unix milliseconds, ISO strings, maps, lists, and existing `%DayEx{}` values.
- Expected parse and validation failures must return `{:error, reason}`. Bang variants may raise.
- Month values in public DayEx APIs remain 1-indexed.
- Unit names should accept the canonical atoms and Day.js-like aliases where doing so does not make the API ambiguous.
- The library must not introduce a GenServer, Agent, process dictionary dependency, or registry for stateless date/time behavior.

### Parsing

- Parsing must support Day.js core inputs and the useful parts of ArraySupport, ObjectSupport, CustomParseFormat, UTC, and Timezone as standard DayEx behavior.
- Custom format parsing must consume the whole input by default.
- Strict parsing must reject impossible dates, invalid ranges, unsupported tokens, invalid offsets, and trailing input.
- Localized parsing must support month names, weekday names where applicable, ordinals, meridiem, localized formats, and locale pre-parse transformations.
- Offset parsing must produce a correct instant when the input includes `Z`, `ZZ`, `X`, or `x`.
- Timezone parsing must expose explicit APIs for "interpret this local input in this named zone" and "convert this instant to this named zone".

### Formatting

- Formatting must cover Day.js core tokens, AdvancedFormat tokens, LocalizedFormat tokens, ISO week tokens, week tokens, quarter tokens, Unix timestamp tokens, timezone offset tokens, ordinal tokens, meridiem tokens, and escaped literals.
- Unsupported tokens should be handled deliberately: either implemented, treated as literals when Day.js does so, or rejected where a strict mode requires it.
- Formatting must use locale modules for names, ordinals, meridiem, week starts, localized formats, and relative time text.
- Formatting must preserve timezone offsets for timezone-aware values.

### Manipulation And Calendar Math

- Add, subtract, start-of, and end-of must support millisecond, second, minute, hour, day, week, month, quarter, and year.
- Calendar units must use calendar math rather than fixed millisecond approximations when Day.js semantics require it.
- Month and year manipulation must clamp invalid dates to the last valid day of the target month.
- DateTime manipulation across DST transitions must document and test how ambiguous and gap times are resolved.
- Quarter, day-of-year, week, ISO week, week year, ISO week year, weekday, and weeks-in-year must be standard calendar features.

### Query

- Query helpers must include before, after, same, same-or-before, same-or-after, between, today, tomorrow, yesterday, leap year, min, and max.
- Unit-granularity query helpers must compare the start of each requested unit consistently.
- Between must support Day.js inclusivity strings.
- Mixed `DateTime` and `NaiveDateTime` comparisons must be explicit and documented.

### Timezone And UTC

- UTC helpers must support construction, conversion, offset inspection, and UTC checks.
- Timezone helpers must use Elixir timezone database support through `tzdata`.
- DayEx must avoid a process-wide mutable default timezone. If a "default" concept is needed, it should be an explicit option or value passed by the caller.
- Ambiguous and gap local times must have documented default behavior and, where useful, options for choosing earlier/later or before/after resolutions.
- Timezone guessing is allowed only as a best-effort helper and must not become a hidden default for parsing.

### Duration

- Duration must support creation from milliseconds, maps, ISO 8601 strings, and diff results.
- Duration must preserve decomposed calendar fields where possible, because "1 month" is not the same concept as "30 days".
- Duration must provide getters, total `as_*` conversions, arithmetic, formatting, ISO output, JSON output, validation, and humanization.
- Duration arithmetic with DayEx values must define when calendar fields are applied before fixed-time fields.
- Negative and fractional durations must be handled consistently or rejected with clear errors.

### Locale And Customization

- Locale data must remain module-based and explicit.
- Locale features must include full and short month names, full, short, and minimal weekday names, relative time strings, ordinals, meridiem strings, week start, localized formats, and optional pre-parse/post-format transforms.
- Locale customization must not mutate global module state. Prefer producing a locale data struct or registered module at compile time.
- DayEx should ship a small maintained set of locales and document how applications add their own locale modules.

### Backplane Managed Service

- The Backplane managed `day::` service should expose stable DayEx features as tools only after the library behavior is tested.
- Tool names and argument contracts should follow the `day::` service conventions already used by Backplane.
- Managed service changes are downstream of this PRD. They should not force DayEx to depend on Backplane.

## Former Day.js Plugin Capability Mapping

Day.js plugins become standard DayEx capabilities. There is no `extend`, `use`, plugin behavior, or runtime registration API.

| Day.js capability | DayEx standard area | Roadmap priority | Notes |
| --- | --- | --- | --- |
| AdvancedFormat | `DayEx.Format` | P1 | Always available advanced tokens. |
| ArraySupport | `DayEx.Parse` | P1 | Parse from Elixir lists and tuples where clear. |
| BadMutable | Out of scope | Never | Contradicts immutable DayEx design. |
| BigIntSupport | Core constructors | P3 | Elixir integers are arbitrary precision, but DateTime range still applies. |
| BuddhistEra | `DayEx.Calendar`, `DayEx.Format` | P3 | Calendar/format feature, not extension. |
| Calendar | `DayEx.Calendar` | P2 | Human calendar-time output. |
| CustomParseFormat | `DayEx.Parse` | P1 | Already started; complete token parity and strict modes. |
| DayOfYear | `DayEx.Calendar` | P1 | Standard getter/setter. |
| DevHelper | Out of scope | Never | Development warnings are not a product requirement. |
| Duration | `DayEx.Duration` | P2 | Already started; complete parity and integration. |
| IsBetween | `DayEx.Query` | P1 | Standard query helper. |
| IsLeapYear | `DayEx.Query` | P1 | Standard query helper. |
| IsSameOrAfter | `DayEx.Query` | P1 | Standard query helper. |
| IsSameOrBefore | `DayEx.Query` | P1 | Standard query helper. |
| IsToday | `DayEx.Query` | P2 | Standard query helper with explicit reference clock option. |
| IsTomorrow | `DayEx.Query` | P2 | Standard query helper with explicit reference clock option. |
| IsYesterday | `DayEx.Query` | P2 | Standard query helper with explicit reference clock option. |
| IsoWeek | `DayEx.Calendar` | P1 | Standard ISO week helpers. |
| IsoWeeksInYear | `DayEx.Calendar` | P1 | Standard ISO calendar helper. |
| LocaleData | `DayEx.Locale` | P2 | Locale data accessors. |
| LocalizedFormat | `DayEx.Format`, `DayEx.Locale` | P1 | Standard localized tokens. |
| MinMax | `DayEx.Query` | P1 | Standard collection helpers. |
| ObjectSupport | `DayEx.Parse` | P1 | Parse from maps with documented keys. |
| PluralGetSet | Core API | P2 | Unit alias normalization. |
| PreParsePostFormat | `DayEx.Locale`, `DayEx.Parse`, `DayEx.Format` | P3 | Explicit locale transforms. |
| QuarterOfYear | `DayEx.Calendar` | P1 | Standard quarter helpers. |
| RelativeTime | `DayEx.RelativeTime` | P1 | Already started; complete locale and threshold support. |
| Timezone | `DayEx.Timezone` | P2 | Standard timezone parse/convert APIs. |
| ToArray | Core conversions | P1 | Standard conversion helper. |
| ToObject | Core conversions | P1 | Standard conversion helper. |
| UpdateLocale | `DayEx.Locale` | P3 | Explicit customization without global mutation. |
| UTC | `DayEx.Timezone` | P1 | Standard UTC helpers. |
| weekOfYear | `DayEx.Calendar` | P1 | Standard locale-aware week helper. |
| WeekYear | `DayEx.Calendar` | P1 | Standard week-year helper. |
| Weekday | `DayEx.Calendar` | P1 | Standard locale-aware weekday helper. |

## Roadmap

### Phase 0: PRD And Compatibility Baseline

Goal: Establish a shared target before more implementation work.

Deliverables:

- This PRD exists under `docs/day_ex/`.
- Current DayEx public behavior is inventoried against Day.js docs.
- Intentional Day.js differences are documented.
- A compatibility fixture format is designed for comparing DayEx output to Day.js output.
- A small fixture set is created from official Day.js examples for parse, format, add, query, duration, locale, UTC, and timezone behavior.

Exit criteria:

- Contributors can identify whether a missing behavior belongs to DayEx core, parse, format, duration, locale, calendar, query, timezone, or out of scope.
- There is no ambiguity that DayEx will not implement a plugin system.

### Phase 1: Core Contract Hardening

Goal: Make the main DayEx API stable enough for broader parity work.

Deliverables:

- Normalize unit handling and aliases across getters, setters, add, subtract, start-of, end-of, diff, and queries.
- Complete constructors for maps, lists, native date/time structs, Unix seconds, Unix milliseconds, ISO strings, and existing DayEx values.
- Define and document mixed `DateTime` and `NaiveDateTime` behavior.
- Complete conversion helpers for ISO, JSON, native structs, maps, lists, dates, Unix seconds, and Unix milliseconds.
- Add explicit validation helpers for DayEx and Duration values.
- Improve README examples around immutable pipelines and Elixir differences.

Exit criteria:

- Core API behavior is stable and covered by public API tests.
- Backplane can depend on the core contract without reaching into internals.

### Phase 2: Format And Parse Parity

Goal: Make token-based formatting and parsing a reliable Day.js migration path.

Deliverables:

- Complete Day.js core format tokens.
- Complete advanced format tokens.
- Complete localized format tokens.
- Complete offset, Unix seconds, Unix milliseconds, ordinal, meridiem, quarter, week, ISO week, and Buddhist era tokens.
- Add strict and non-strict parse modes where Day.js behavior differs.
- Add localized parsing for month names, ordinals, meridiem, and localized formats.
- Add parse support for arrays and maps.
- Add round-trip tests for parse and format where the operation is reversible.

Exit criteria:

- Existing Day.js format strings used by Backplane or examples can be ported with documented differences only.
- Unsupported tokens either have an issue, a documented reason, or a deliberate out-of-scope decision.

### Phase 3: Calendar Math And Query Parity

Goal: Complete day, week, month, quarter, year, and range behavior.

Deliverables:

- Complete calendar-aware add/subtract for day, week, month, quarter, and year.
- Complete start-of and end-of for all supported units.
- Complete diff behavior for fixed-time and calendar units, including floating diffs.
- Add today, tomorrow, yesterday, leap year, before, after, same, same-or-before, same-or-after, between, min, and max.
- Add day-of-year, quarter, locale week, ISO week, week year, ISO week year, weekday, and weeks-in-year helpers.
- Document reference-clock options for "today" style helpers.

Exit criteria:

- Calendar and query helpers match Day.js behavior for documented fixtures.
- DST, month-end, leap-year, and ISO-week edge cases are tested.

### Phase 4: UTC And Timezone Parity

Goal: Make timezone behavior explicit, tested, and safe for application use.

Deliverables:

- Complete UTC construction, conversion, offset, and UTC-check helpers.
- Complete parse-in-zone and convert-to-zone APIs.
- Define ambiguous and gap local time behavior.
- Add options for ambiguous and gap resolution if the default is not enough.
- Add timezone formatting and parsing fixtures for offsets and named zones.
- Add best-effort timezone guessing only if it can be implemented without hidden mutable defaults.

Exit criteria:

- Timezone code has focused tests for named zones, offsets, DST gaps, DST ambiguity, UTC conversion, and local conversion.
- The API remains explicit and does not rely on global mutable defaults.

### Phase 5: Duration Parity

Goal: Make Duration a complete first-class DayEx feature.

Deliverables:

- Complete duration constructors from milliseconds, maps, ISO 8601 strings, and DayEx diffs.
- Add duration validation and non-bang parse variants.
- Complete getters, total conversions, arithmetic, formatting, ISO output, JSON output, humanize, and locale handling.
- Define duration normalization rules.
- Define how calendar duration fields apply to DayEx values.
- Add duration tests for negative values, fractional seconds, mixed fields, ISO round-trips, and humanization thresholds.

Exit criteria:

- Duration can be used independently and with DayEx date/time values.
- Duration behavior is documented where calendar approximations are unavoidable.

### Phase 6: Locale And Customization Parity

Goal: Make locale behavior complete without global mutation.

Deliverables:

- Expand locale data to support localized formats, calendar text, pre-parse, post-format, ordinals, meridiem, and week starts.
- Provide locale data accessors for month and weekday listings.
- Provide a safe customization path that does not mutate global DayEx state.
- Document how application-specific locale modules are added.
- Audit shipped locale modules for consistency.

Exit criteria:

- Locale-dependent formatting, parsing, relative time, calendar time, and week behavior are covered.
- Locale customization is explicit and does not require a plugin system.

### Phase 7: Compatibility Harness

Goal: Prevent regressions while moving toward Day.js parity.

Deliverables:

- Add a fixture format for Day.js input, Day.js expected output, DayEx input, expected DayEx output, locale, timezone, and intentional differences.
- Add a focused test helper for running fixture groups.
- Add property tests for parse/format round trips, add/subtract inverses where valid, comparison transitivity, range containment, duration ISO round trips, and timezone conversion invariants.
- Add documentation that explains how to add a compatibility fixture when implementing a new Day.js behavior.

Exit criteria:

- Each roadmap phase adds fixtures before or alongside implementation.
- Compatibility failures clearly indicate whether the behavior is a regression, a missing feature, or an intentional DayEx difference.

### Phase 8: Documentation, Packaging, And Backplane Service Expansion

Goal: Make DayEx usable as a library and as the foundation for Backplane's managed day service.

Deliverables:

- Expand README with installation, constructors, parse/format, timezone, duration, locale, and compatibility notes.
- Add API docs and examples for each standard module.
- Add a migration guide from common Day.js usage to DayEx.
- Prepare Hex package metadata.
- Expand Backplane `day::` tools only after the underlying DayEx APIs are stable and tested.

Exit criteria:

- A new Elixir user can discover the equivalent Day.js capability without learning a plugin system.
- Backplane exposes stable DayEx behavior through managed tools without coupling DayEx to Backplane internals.

## Implementation Decisions

- DayEx will implement Day.js behavior as normal modules and public functions, not as plugins.
- DayEx will keep the existing pure-function, immutable data model.
- DayEx will not use runtime processes to organize stateless date/time behavior.
- DayEx will keep Elixir-style `{:ok, value}` and `{:error, reason}` returns for fallible operations.
- DayEx will provide bang variants where fail-fast behavior is useful.
- DayEx will keep 1-indexed months as an intentional Elixir-facing difference from Day.js.
- DayEx will prefer explicit options over global mutable defaults for locale, timezone, and reference-clock behavior.
- DayEx will use existing Elixir calendar and timezone primitives before adding custom date/time math.
- DayEx will centralize unit normalization so that parse, format, manipulation, diff, duration, and query behavior do not drift.
- DayEx will treat Backplane managed service integration as a consumer of the library, not part of the library core.
- DayEx will document intentional differences instead of hiding them behind compatibility claims.
- DayEx will use compatibility fixtures to guide behavior, but it does not need to reproduce JavaScript package architecture.

## Testing Decisions

- Tests should target public behavior, not private helpers.
- The highest-value test boundary is the DayEx public API and standard modules.
- Each roadmap phase should add tests before or with implementation.
- Use fixture-based tests for known Day.js compatibility examples.
- Use property tests for invariants: parse/format round trips, add/subtract inverses where calendar math allows, comparison transitivity, between containment, duration ISO round trips, and timezone instant preservation.
- Use explicit tests for edge cases: leap years, month ends, DST gaps, DST ambiguity, negative Unix timestamps, fractional timestamps, invalid dates, invalid format tokens, invalid offsets, mixed naive/aware comparisons, and locale-specific output.
- Keep DayEx tests independent of Backplane database, Phoenix, MCP, and managed service state.
- Managed `day::` service tests should verify argument contracts and output shape after the library behavior is already covered.
- When running PRD or implementation verification in this repo, use the scoped DayEx test command rather than the full umbrella unless the change crosses app boundaries.

## Out Of Scope

- A Day.js-style plugin system.
- Runtime plugin loading, extension macros, plugin registries, or monkey patching.
- The Day.js `BadMutable` behavior.
- Hidden global mutable locale or timezone defaults.
- Browser, Node.js, or JavaScript package compatibility.
- Full drop-in JavaScript method naming where it conflicts with clear Elixir conventions.
- Replacing Elixir's native calendar and timezone primitives.
- Backplane admin UI changes as part of the DayEx library roadmap.
- A complete world-locale dataset in the first parity pass.

## Further Notes

- The current implementation already has the first foundation: immutable `%DayEx{}`, core parse/format/manipulation/query functions, relative time, locale modules, duration, timezone support, and property tests.
- The next engineering step after this PRD should be a task plan that breaks the roadmap into independently mergeable slices.
- Official Day.js documentation reviewed for this PRD includes [Plugin](https://day.js.org/docs/en/plugin/plugin), [Format](https://day.js.org/docs/en/display/format), [String + Format](https://day.js.org/docs/en/parse/string-format), [Add](https://day.js.org/docs/en/manipulate/add), and [i18n](https://day.js.org/docs/en/i18n/i18n) docs.
- The Day.js docs describe plugins as independent modules that extend Day.js. DayEx intentionally keeps the capabilities but rejects the extension mechanism.
- Day.js format documentation distinguishes core format tokens from AdvancedFormat and LocalizedFormat tokens. DayEx should expose those token families as standard formatting support.
- Day.js parse documentation for String + Format is the closest compatibility target for DayEx token parsing.
- Day.js manipulate docs are the compatibility target for add/subtract and unit behavior.
- Day.js i18n docs are the compatibility target for locale-specific output, but DayEx must keep customization explicit and immutable.

## PRD Quality Checklist

- [x] Scope is limited to the DayEx roadmap and requirements.
- [x] The no-plugin-system decision is explicit.
- [x] Former Day.js plugin capabilities are mapped to standard DayEx modules.
- [x] Roadmap phases are ordered and have exit criteria.
- [x] Testing decisions identify the public behavior boundary.
- [x] Out-of-scope items are explicit.
- [x] Intentional Day.js differences are documented.
