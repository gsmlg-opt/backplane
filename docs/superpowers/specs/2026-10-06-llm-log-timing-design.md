# LLM log TTFT and T/S

Approved scope: collect accurate streaming content timing and display TTFT and
T/S in the LLM log list and detail views. No database migration is required.

TTFT measures the monotonic interval from the proxy request lifecycle start to
the arrival of the first complete SSE event containing nonempty generated text,
reasoning, or tool arguments. Heartbeats, role-only events, lifecycle-only events,
empty deltas, and usage-only events do not start this clock. Timestamp arrival
before asynchronous observation so worker scheduling does not add latency.

The generation interval runs from first content until stream finalization. T/S
is provider-reported output tokens multiplied by 1000 and divided by this interval
in milliseconds; preserve each provider's output/reasoning token semantics.

Reuse `ttft_ms` and `stream_duration_ms`, and mark the new interpretation with
`metadata.timing.basis = "first_content"`. Unmarked historical records cannot be
backfilled accurately. The UI displays an em dash for those records, non-streaming
responses, unobserved content, missing output counts, and nonpositive generation
intervals. A known zero output count with a valid interval displays 0.0 T/S.

Observation remains bounded and must not alter forwarded bytes or fail requests.
Dropped chunks or framing failures must not fabricate first-token measurements.
Tests cover OpenAI Chat/Responses, Anthropic, Google/Antigravity, fragmented SSE,
empty/control events, tool/reasoning content, worker delays, missing timings,
persistence, and list/detail rendering. Browser checks use local fixtures, with
no live provider requests.
