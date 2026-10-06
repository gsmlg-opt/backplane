# LLM Log Timing Implementation Plan

> For agentic workers: execute the independent collector and admin UI tasks in
> parallel with disjoint ownership; serialize all Mix/build commands in the parent.

**Goal:** Accurate streaming TTFT and output T/S in LLM log list and detail views.

**Architecture:** Keep bounded content detection and arrival timestamps in the
LLM usage accumulator. Pass request start from AccessEvent, persist through the
existing writer, and derive T/S when rendering trusted timing records.

**Tech Stack:** Elixir/OTP, bounded SSE framing, existing Ecto log schema, Phoenix
LiveView and DuskMoon components.

## Collector

- [x] Add failing regression tests in
  `apps/backplane_llama/test/backplane/llm/usage_accumulator_timing_test.exs` for control
  frames, fragmented nonempty content, reasoning/tool data, supported protocols,
  delayed owner processing, finish time, and unavailable observation.
- [x] Run the focused accumulator tests and verify failures expose missing behavior.
- [x] Update `apps/backplane_llama/lib/backplane/llm/usage_accumulator.ex` with bounded
  content framing; capture arrival before enqueue and completion before snapshot.
  Accept `started_at_mono` in constructor options and attach the timing basis marker.
- [x] Verify accumulator regressions and existing protocol observation tests pass.

## Request lifecycle and persistence

- [x] Add failing persistence tests in
  `apps/backplane_llama/test/backplane/llm/access_event_test.exs`: simulate 500 ms
  of routing before stream creation and require persisted TTFT >= 500 ms; require
  a usage-only stream to persist nil timings while retaining output count zero.
- [x] Pass `state.started_at_mono` through the default accumulator factory in
  `apps/backplane_llama/lib/backplane/llm/access_event.ex`; preserve injected
  one-argument factories and nonstreaming nil timing behavior.
- [x] Verify the persisted basis is `first_content`, counts survive unchanged,
  and focused local simulated-upstream integration tests preserve native bytes.

## Admin UI

- [x] Add failing list/detail tests in
  `apps/backplane_admin/test/backplane/admin/live/logs_live_test.exs` for 250 ms
  TTFT, 95 output tokens over 2000 ms yielding 47.5 T/S, historical records,
  missing/zero intervals, nonstreaming rows, and known zero output.
- [x] Add TTFT/T/S fields and explanatory titles in
  `apps/backplane_admin/lib/backplane/admin/live/logs_llm_live.ex`. Require
  `stream == true` and the new timing basis; derive throughput from existing fields.
- [x] Verify focused LiveView tests and local browser list/detail layouts.

## Validation and documentation

- [x] Update observability and Google timing documentation to match final semantics.
- [x] Run changed-file formatting and focused tests, then warnings-as-errors
  compilation and `git diff --check`.
- [x] Record reusable timing semantics in Agent Note with `project=backplane`.
- [x] Report verification and limits; commit and push only after explicit user
  authorization. Release and deployment remain outside this work.

Validation: 105 focused Llama tests and 16 admin tests passed; final timing/UI
recheck passed 28 + 16 tests. Changed-file formatting and strict Credo,
warnings-as-errors compilation, and diff checks passed. Browser list/detail
checks passed at 1440 and 375 px; temporary fixtures removed. The user subsequently
authorized commit and push. No release or deploy requested. DuskMoon tooltip compatibility is tracked in
https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/173 with a marked native
label workaround. Full tests and Dialyzer were not run.
