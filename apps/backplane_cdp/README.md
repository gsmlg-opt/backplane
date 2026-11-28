# Backplane CDP

`backplane_cdp` is an Elixir library for connecting to a local Chrome DevTools
Protocol endpoint. It provides the `Backplane.CDP` command API, the `mix cdp`
task, and the session-based tool catalog used by the Backplane Host Agent.

## Installation

Add `{:backplane_cdp, "~> 1.10"}` to your Mix dependencies and run
`mix deps.get`. The package version follows the Backplane release version.

## Usage

With Chrome remote debugging available on the local port `9222`, list pages
from your Mix project:

```sh
BACKPLANE_CDP_PORT=9222 mix cdp list_pages
```

Run `mix cdp --help` for the command list. From Elixir, use
`Backplane.CDP.call("list_pages", %{})` with the same port configured.
