# Superseded draft — do not submit

Existing issue [gsmlg-dev/http_fetch#152](https://github.com/gsmlg-dev/http_fetch/issues/152)
(item 2) covers this blocker. Initially verified open on 2026-11-05; now closed with source fix `27e5fe6`.
As of 2026-11-06 03:23 UTC, rc.3 is not published on Hex; see the current
checkpoint in `docs/responses-websocket.md`.
Latest published `http_web_socket 1.0.0-rc.2` still lacks the public metadata API.
The text below records Backplane-specific acceptance requirements only; no duplicate
issue or comment was created.

Requesting repository: gsmlg-opt/backplane, branch work, main base 902b5cc4cdcbcc6ed5f5e2c4cb36f3b3fee0fc7f.
Severity: blocker. Issue type: Feature.

Backplane needs to proxy native Responses WebSocket sessions without discarding handshake response metadata. In locked http_web_socket 0.21.19, HTTP.WebSocket.Event.Open contains only target/type; protocol/1 exposes the selected subprotocol but no public API exposes successful handshake response headers. connection.ex receives headers and discards them after Handshake.validate_response. status/1 exposes queue/transport state only.

Expected: a public immutable handshake result with status, response headers (preserving repeated values), selected subprotocol, plus bounded non-upgrade rejection metadata. Make it available before admitting application frames so a proxy can propagate allowed upstream session/routing metadata and selected protocol in its downstream upgrade. Continue to validate the handshake and prohibit credential leakage. Test custom response headers, rejected upgrades, selected protocol, owner death and failed connection cleanup for H1 and supported H2.

Reproduction: inspect lib/http/web_socket/event.ex and public exports in lib/http/web_socket.ex from https://repo.hex.pm/tarballs/http_web_socket-0.21.19.tar. No public header result is available after Event.Open. Backplane cannot safely claim transparent handshake forwarding using this version. Per repository policy no local private-state or alternate-client workaround is being implemented.
