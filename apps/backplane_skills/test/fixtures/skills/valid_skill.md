---
name: elixir-testing
description: Best practices for testing Elixir applications with ExUnit
tags:
  - elixir
  - testing
  - exunit
model: claude-sonnet-4-20250514
version: 1
---

# Elixir Testing Best Practices

## Setup

Use `ExUnit.CaseTemplate` for shared setup across test modules.

## Assertions

Prefer pattern matching over `assert x == y`:

```elixir
assert {:ok, %{name: "Alice"}} = create_user("Alice")
```

## Async Tests

Mark tests `async: true` when they don't share global state.
