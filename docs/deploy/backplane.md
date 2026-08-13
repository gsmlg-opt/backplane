# Deploying Backplane {{VERSION}}

Backplane is a self-hosted MCP hub and LLM proxy. It needs PostgreSQL and a
small boot-time TOML config; everything operational is managed afterwards on
the separate administration endpoint.

## Option 1 — Docker (recommended)

Images are published to GHCR for every release:

```sh
docker pull ghcr.io/gsmlg-dev/backplane:{{VERSION}}
```

### docker compose

```yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: backplane
      POSTGRES_PASSWORD: change-me
      POSTGRES_DB: backplane
    volumes:
      - pgdata:/var/lib/postgresql/data

  backplane:
    image: ghcr.io/gsmlg-dev/backplane:{{VERSION}}
    depends_on:
      - postgres
    ports:
      - "4100:4100"
      # Do not publish this on an untrusted interface. Use a loopback bind or a
      # trusted-network reverse proxy until application-level admin auth ships.
      - "127.0.0.1:4101:4101"
    environment:
      BACKPLANE_CONFIG: /etc/backplane/backplane.toml
      SECRET_KEY_BASE: <64+ char random string>
      PHX_HOST: backplane.example.com
    volumes:
      - ./backplane.toml:/etc/backplane/backplane.toml:ro

volumes:
  pgdata:
```

The container entrypoint is `/app/bin/backplane start`. Port `4100` is the
public API/MCP/LLM surface; port `4101` is the separate admin UI and must remain
reachable only from a trusted network.

## Option 2 — OTP release tarball

Download the tarball for your platform from this release page
(`backplane-<version>-linux-x64.tar.gz` or `linux-arm64`), verify the
`.sha256`, then:

```sh
tar -xzf backplane-<version>-linux-x64.tar.gz -C /opt
export BACKPLANE_CONFIG=/etc/backplane/backplane.toml
export SECRET_KEY_BASE=<64+ char random string>
export PHX_HOST=backplane.example.com
/opt/backplane/bin/backplane start
```

## Boot configuration (`backplane.toml`)

See `config/backplane.toml.example` in the repository. The TOML covers only
boot concerns:

```toml
[backplane]
host = "0.0.0.0"
port = 4100

[database]
url = "postgres://backplane:change-me@postgres:5432/backplane"
```

## Environment variables

| Variable | Purpose |
|----------|---------|
| `BACKPLANE_CONFIG` | Path to the TOML config (default: `backplane.toml`) |
| `SECRET_KEY_BASE` | Phoenix secret for cookies/sessions |
| `PHX_HOST` | Public hostname |
| `BACKPLANE_API_PORT` | Public API/MCP/LLM port (falls back to `BACKPLANE_PORT`, `PORT`, then 4100) |
| `BACKPLANE_ADMIN_PORT` | Separate admin UI port (default 4101) |
| `BACKPLANE_API_URL` | Public API origin and OAuth issuer, for example `https://backplane.example.com` |
| `BACKPLANE_ADMIN_URL` | Trusted admin origin used to build OAuth callbacks, for example `https://admin.backplane.internal` |
| `FIGMA_MCP_CLIENT_ID` | Figma-issued OAuth client ID for the shared remote MCP connection |
| `FIGMA_MCP_CLIENT_SECRET` | Figma-issued OAuth client secret; keep it only in deployment secrets |

## After first boot

Open `http://<trusted-host>:4101/` to configure upstream MCP servers, LLM
providers, credentials, and client tokens. There is no admin route on port
`4100`. Until application-level admin authentication is introduced, never
expose `4101` directly to the Internet. Bind it to loopback, a private overlay,
or a reverse proxy that is reachable only from a trusted network. The split
public/admin Caddy example lives in `docs/deploy/caddy.md`.

For Memory V2 migration, recovery, and qualification procedures, see the
attached `memory-v2-operations.md`, `memory-v2-release.md`, and
`memory-v2-qualification.md` release documents.

### Figma remote MCP OAuth

Backplane must be approved for the
[Figma MCP server catalog](https://www.figma.com/mcp-catalog/) before a live
connection can complete. Register this exact public HTTPS redirect URI for the
approved OAuth client:

```text
${BACKPLANE_ADMIN_URL}/oauth/callback
```

Set `FIGMA_MCP_CLIENT_ID` and `FIGMA_MCP_CLIENT_SECRET`, restart Backplane, then
open **Settings → Credentials → Connect Figma MCP**. The default credential
name is `figma-mcp`. Authorizing it stores one shared Figma account for every
Backplane caller; create a differently named credential only when another
global upstream should use another shared account.

Configure the remote upstream in **MCP Hub → Upstreams** with:

```text
URL: https://mcp.figma.com/mcp
Auth scheme: bearer
Credential: figma-mcp
```

Backplane requests `mcp:connect`, refreshes the encrypted token before expiry,
and never stores the OAuth client secret in the credential row.
