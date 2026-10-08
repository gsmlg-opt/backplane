# Changelog

## Unreleased

- Fixes single Peri validation errors crashing tool and prompt input handling,
  preserves nested error details, and makes `Schema.validator/1` callbacks safe
  to compose with Peri custom validators.
- Adds Agent Note HTTP parity regression coverage and documents upgrading from
  retired `1.6.3` to published `1.10.12` for modern discovery and tool calls.
- Fixes Streamable HTTP `:auto` negotiation so a valid `server/discover`
  `-32601 Method not found` response falls back to the canonical legacy
  initialization flow while explicit version pins remain strict.
- Adds complete MCP `2026-07-28` client and server support over Streamable HTTP and stdio.
- Defaults new clients to `protocol_version: :auto`, using modern `server/discover` with evidence-based legacy fallback while preserving explicit version pins.
- Adds stateless modern request execution, required metadata and HTTP headers, modern result and cache envelopes, MRTR, and request-owned subscriptions.
- Preserves arbitrary JSON Schema 2020-12 wire maps and every JSON `structuredContent` shape while safely disabling unsupported local validation.
- Adds modern authorization issuer, registration-selection, and secure credential-store helpers.
- Freezes official `2026-07-28` client and server conformance coverage and keeps all legacy protocol versions available.
- Defers the optional modern `io.modelcontextprotocol/tasks` extension; legacy `2025-11-25` Tasks support remains available.

## 0.4.0

- Keeps the Hex package version synchronized with Backplane releases.
- Restores required Hex publication to the Backplane release workflow.

## 0.3.1

- Integrates `backplane_mcp_protocol` into the Backplane umbrella build.
- Corrects package source and documentation links for the umbrella location.

## 0.3.0

- Provides Backplane.McpProtocol client and server primitives for MCP clients, servers, components, transports, JSON-RPC messages, SSE parsing, task handling, and session storage.
- Supports Streamable HTTP, SSE, stdio, and WebSocket-oriented MCP integration paths.
- Includes ExDoc guides for building MCP clients, servers, and common recipes.

## Retired releases

### 1.6.3

This release used the Backplane umbrella version by mistake and is retired.
Use a supported release such as `1.10.12` for MCP `2026-07-28` support.
