Submitted: https://github.com/gsmlg-dev/http_fetch/issues/155 (internal request).

Requesting repository: gsmlg-opt/backplane, branch work, main base bc200d0110fc6ce075152485599dc92f272577d5.
Issue type: Feature. Severity: blocker.

#152 is fixed and http_web_socket 1.0.0-rc.3 is published, but Backplane cannot adopt it in its supported dependency graph. This is a release-compatibility request, not a duplicate request for #152's transport implementation.

Latest published dependency constraints checked on 2026-11-06:
- gaoxy_http 0.14.1 requires http_core ~> 0.21 and >= 0.21.17.
- duskmoon_npm 10.1.1 requires http_fetch ~> 0.20.0 or ~> 0.21.0.
- duskmoon_quickbeam 10.1.1 requires http_fetch/http_event_source/http_web_socket ~> 0.20.0 or ~> 0.21.0.
- phoenix_socket_client 0.8.9 requires http_web_socket ~> 0.21.14.
- http_web_socket rc.3 requires exact rc.3 http_core/http_runtime, whereas http_fetch 0.21.19 requires exact 0.21.19 http_core/http_runtime.

Expected: publish a coordinated supported 0.21.x backport of #152 (and required cleanup contracts), or provide a released compatible dependency set for Gaoxy/DuskMoon/Phoenix Socket Client and the HTTP family. Do not silently override incompatible constraints. The rc family also removes OTP :ssl selections currently used by Relayixir, so a compatible backport is preferable to an unrelated whole-gateway TLS migration.

Reproduction: use http_web_socket ==1.0.0-rc.3 with gaoxy_http ==0.14.1, or with http_fetch ==0.21.19. Their http_core constraints have no intersection. See https://hex.pm/api/packages/http_web_socket/releases/1.0.0-rc.3 and the corresponding latest package release APIs for the constraints.

No production dependency overrides, vendoring or Git pins have been applied. Standalone rc.3 publication probes remain separate from the umbrella. Existing Responses configuration and pure message codec work can proceed; gateway transport integration remains blocked.
