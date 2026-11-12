# Backplane OAuth

OAuth 2.0 and OpenID Connect provider core for Elixir applications, maintained
as part of [Backplane](https://github.com/gsmlg-opt/backplane).

Backplane OAuth is a fork of [Boruta](https://github.com/malach-it/boruta_auth)
2.3.8. Modules live under `Backplane.Oauth` (upstream `Boruta.Oauth.*` is folded
into it, other `Boruta.*` modules move under `Backplane.Oauth.*`), and the OTP
application is `:backplane_oauth`.

It implements the business rules of:

- [RFC 6749 - The OAuth 2.0 Authorization Framework](https://tools.ietf.org/html/rfc6749)
- [RFC 7662 - OAuth 2.0 Token Introspection](https://tools.ietf.org/html/rfc7662)
- [RFC 7009 - OAuth 2.0 Token Revocation](https://tools.ietf.org/html/rfc7009)
- [RFC 7636 - Proof Key for Code Exchange by OAuth Public Clients](https://tools.ietf.org/html/rfc7636)
- [RFC 7521 - Assertion Framework for OAuth 2.0 Client Authentication and Authorization Grants](https://www.rfc-editor.org/rfc/rfc7521)
- [RFC 7523 - JSON Web Token (JWT) Profile for OAuth 2.0 Client Authentication and Authorization Grants](https://tools.ietf.org/html/rfc7523)
- [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html)
- [OpenID Connect Dynamic Client Registration 1.0](https://openid.net/specs/openid-connect-registration-1_0.html)

## Installation

```elixir
def deps do
  [
    {:backplane_oauth, "~> 1.10"}
  ]
end
```

## Configuration

```elixir
config :backplane_oauth, Backplane.Oauth,
  repo: MyApp.Repo,
  issuer: "https://auth.example.com",
  contexts: [
    resource_owners: MyApp.ResourceOwners
  ]
```

See `Backplane.Oauth.Config` for every option and its default.

## Database migrations

```sh
mix backplane_oauth.gen.migration
```

The task copies the `oauth_clients`, `oauth_scopes` and `oauth_tokens`
migrations into your repository and only creates the ones that are missing.

## Phoenix controllers

```sh
mix backplane_oauth.gen.controllers
```

Run it from your `*_web` application root to generate OAuth and OpenID Connect
controllers, views, templates and tests.

## Usage

`Backplane.Oauth` exposes `token/2`, `preauthorize/3`, `authorize/3`,
`introspect/2` and `revoke/2`. Each takes a `Plug.Conn` and a module that
implements the matching `Backplane.Oauth.*Application` callbacks, so your
controllers render success and error responses. `Backplane.Oauth.Openid`
provides the OpenID Connect userinfo, JWKS and dynamic registration flows.

## License

MIT. The LICENSE file keeps the original Boruta copyright notice.
