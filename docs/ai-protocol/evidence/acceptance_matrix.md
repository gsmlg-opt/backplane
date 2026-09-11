# Acceptance Matrix

## Initial ledger

| Acceptance | Status | Evidence |
| --- | --- | --- |
| T03, T08, T27 | `in_progress` | Core cases are implemented in `apps/backplane_ai_protocol` and pass under `mix test apps/backplane_ai_protocol/test/backplane/ai_protocol_test.exs --seed 0`; W2 fixtures and broader evidence remain. |
| T06, T07, T28 | `in_progress` | W1.3 pure lifecycle and gate tests pass; real transport/resource evidence remains. |
| T21 | `in_progress` | W1.4 pure preflight tests pass; static/midstream integration evidence remains. |
| T09, T10 | `in_progress` | W1.5 wire contract, duplicate detection, credit model, and connection retirement implemented and tested; real WS evidence remains. |
| T01–T05, T11–T20, T24–T26 | `not_started` | Assigned work packages have not started. |
| T22 | `in_progress` | Independent lab consumer build/start passed; actual production artifact installation remains W5/W8. See `w1_1_report.md`. |
| T23 | `in_progress` | Protocol dependency tree is empty and release composition is unchanged; release/process inspection remains W5/W8. See `w1_1_report.md`. |

R01–R14 remain active until corresponding evidence exists.
