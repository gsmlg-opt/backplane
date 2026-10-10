# Appbar Version Badge Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the independent metadata implementation, then verify the integrated UI.

**Goal:** Show the current version beside the brand, with a dev suffix and a matching-color details tooltip.

**Architecture:** An admin-owned metadata module captures compile-time environment/Git information and reads explicit deployment metadata at runtime. The existing app layout renders a secondary DuskMoon badge and tooltip. Missing release time remains unavailable.

**Tech Stack:** Elixir, Phoenix HEEx, phoenix_duskmoon.

---

- [x] Add `apps/backplane_admin/lib/backplane/admin/build_info.ex` and focused tests under `apps/backplane_admin/test/backplane/admin/build_info_test.exs`; verify dev/prod labels, metadata precedence and missing values.
- [x] Add the badge and tooltip to `apps/backplane_admin/lib/backplane/admin/components/layouts/app.html.heex`; keep layout edits in the parent agent and metadata edits in the worker.
- [x] Point the root stylesheet at the current admin CSS output with an application-relative runtime manifest directory; refresh generated JavaScript assets.
- [x] Format only changed Elixir/HEEx files, run the focused metadata tests, and inspect the rendered appbar on port 4221. Check focus/hover tooltip and exact badge/tooltip colors in both themes.
- [x] Save one verified Agent Note labeled `project: backplane`. Leave all changes uncommitted.
