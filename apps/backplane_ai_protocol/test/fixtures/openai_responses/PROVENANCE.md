# Responses image tool-output fixtures

Independently authored native request JSON, 2026-10-26, for Backplane #112.
These examples are derived from the official schema, not from this codec's
output or an upstream capture:

- https://developers.openai.com/api/reference/resources/responses/methods/create
- https://developers.openai.com/api/docs/guides/function-calling
- https://developers.openai.com/api/docs/guides/images-vision

`image_tool_results.json` specifies both function and custom outputs with
ordered text/image/text arrays, shared inline PNG bytes and explicit `original`
detail. The canonical test inputs deliberately mix bare base64 and an already
prefixed URI; their native JSON must be identical without a duplicated prefix.
The test's separately authored expected native image maps additionally cover
all four details and the explicit `auto` default, both data forms and all four
supported MIME values. Unsupported/malformed forms and metadata are independent
canonical inputs that must fail before transport.

`FunctionCallOutput.output` and `CustomToolCallOutput.output` admit native
input-text/image/file arrays; this fixture exercises only text/image. Native
image data URLs use `image_url`, and detail is an exact provider string.
Function lifecycle status cannot stand in for semantic tool-error status.

The regression test reloads canonical JSON through public constructors, encodes
with the public codec and sends the JSON through OTP's HTTP client to an actual
loopback TCP listener. The captured bytes and parsed native document must
match. This is local functional evidence only, without credentials, external
requests or a claim that any remote model accepts `original` or these images.
