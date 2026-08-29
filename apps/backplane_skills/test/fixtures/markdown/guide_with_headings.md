# Getting Started Guide

Welcome to the project. This guide covers setup and basic usage.

## Installation

Install the dependencies:

```bash
mix deps.get
mix ecto.setup
```

## Configuration

Configure the application in `config/runtime.exs`:

```elixir
config :myapp, :api_key, System.get_env("API_KEY")
```

## Usage

Start the server:

```bash
mix phx.server
```

### API Endpoints

The following endpoints are available:

- `GET /api/users` — List all users
- `POST /api/users` — Create a user

### Authentication

All API requests require a bearer token in the `Authorization` header.

## Troubleshooting

If you encounter issues, check the logs in `log/dev.log`.
