# syntax=docker/dockerfile:1.7

ARG ELIXIR_IMAGE=hexpm/elixir:1.18.4-erlang-28.0.2-debian-bookworm-20250630-slim
ARG DEBIAN_IMAGE=debian:bookworm-slim

FROM ${ELIXIR_IMAGE} AS builder

ARG VERSION=0.1.0
ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    unzip \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock package.json bun.lock ./
COPY config ./config
COPY apps/backplane/mix.exs ./apps/backplane/mix.exs
COPY apps/backplane_data_case/mix.exs ./apps/backplane_data_case/mix.exs
COPY apps/backplane_llama/mix.exs ./apps/backplane_llama/mix.exs
COPY apps/backplane_mcp/mix.exs ./apps/backplane_mcp/mix.exs
COPY apps/backplane_mcp_protocol/mix.exs ./apps/backplane_mcp_protocol/mix.exs
COPY apps/backplane_memory/mix.exs ./apps/backplane_memory/mix.exs
COPY apps/backplane_monitor/mix.exs ./apps/backplane_monitor/mix.exs
COPY apps/backplane_skills/mix.exs ./apps/backplane_skills/mix.exs
COPY apps/backplane_system/mix.exs ./apps/backplane_system/mix.exs
COPY apps/backplane_telemetry/mix.exs ./apps/backplane_telemetry/mix.exs
COPY apps/backplane_api/mix.exs apps/backplane_api/package.json ./apps/backplane_api/
COPY apps/backplane_admin/mix.exs apps/backplane_admin/package.json ./apps/backplane_admin/
COPY apps/day_ex/mix.exs ./apps/day_ex/mix.exs
COPY apps/relayixir/mix.exs ./apps/relayixir/mix.exs

RUN mix deps.get --only prod
RUN mix "do" --app backplane_api assets.setup \
  && mix "do" --app backplane_admin assets.setup \
  && ./_build/bun install --frozen-lockfile

COPY . .

RUN mix deps.compile
RUN mix "do" --app backplane_api assets.deploy \
  && mix "do" --app backplane_admin assets.deploy
RUN mix release backplane --overwrite --version "${VERSION}"

FROM ${DEBIAN_IMAGE} AS runtime

ARG BUILD_DATE=unknown
ARG GIT_REF=unknown
ARG VERSION=unknown
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="Backplane" \
  org.opencontainers.image.description="Self-hosted MCP hub and LLM proxy" \
  org.opencontainers.image.source="https://github.com/gsmlg-dev/backplane" \
  org.opencontainers.image.created="${BUILD_DATE}" \
  org.opencontainers.image.revision="${VCS_REF}" \
  org.opencontainers.image.ref.name="${GIT_REF}" \
  org.opencontainers.image.version="${VERSION}" \
  io.gsmlg.backplane.git-ref="${GIT_REF}" \
  io.gsmlg.backplane.version="${VERSION}" \
  io.gsmlg.backplane.built-at="${BUILD_DATE}"

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    libgcc-s1 \
    libncurses6 \
    libstdc++6 \
    openssl \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --system --gid 10001 backplane \
  && useradd --system --uid 10001 --gid backplane --home-dir /app --shell /usr/sbin/nologin backplane

WORKDIR /app

COPY --from=builder --chown=backplane:backplane /app/_build/prod/rel/backplane ./

ENV BACKPLANE_BUILD_DATE="${BUILD_DATE}" \
  BACKPLANE_API_PORT=4100 \
  BACKPLANE_ADMIN_PORT=4101 \
  BACKPLANE_GIT_REF="${GIT_REF}" \
  BACKPLANE_PORT=4100 \
  BACKPLANE_VERSION="${VERSION}" \
  HOME=/app \
  LANG=C.UTF-8 \
  PHX_SERVER=true \
  PORT=4100

USER backplane

EXPOSE 4100 4101

ENTRYPOINT ["/app/bin/backplane"]
CMD ["start"]
