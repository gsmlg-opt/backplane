# syntax=docker/dockerfile:1.7

ARG ELIXIR_IMAGE=hexpm/elixir:1.18.4-erlang-28.0.2-debian-bookworm-20250630-slim@sha256:7dc0ae78d310f70b7fc00a9ed0124ad0bed485e2e16883a43b505b407f2e8a3e
ARG DEBIAN_IMAGE=debian:bookworm-slim

# The old-baseline BEAM toolchain runs on newer libc only in this build stage.
FROM --platform=$BUILDPLATFORM ${ELIXIR_IMAGE} AS beam-tools

FROM --platform=$BUILDPLATFORM ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944 AS web-assets-builder

ARG VERSION=0.1.0
ARG VCS_REF
ENV MIX_ENV=prod DUSKMOON_NATIVE_MODE=precompiled LANG=C.UTF-8
WORKDIR /app

COPY --from=beam-tools /usr/local /usr/local
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git unzip \
    libncurses6 libodbc2 libsctp1 libssl3t64 libstdc++6 netbase \
  && rm -rf /var/lib/apt/lists/*
RUN erl -noshell -eval '"28" = erlang:system_info(otp_release), halt(0).' \
  && elixir -e 'unless Version.match?(System.version(), "~> 1.18.0"), do: raise("unsupported asset Elixir")' \
  && mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock package.json package-lock.json ./
COPY config ./config
COPY apps/backplane/mix.exs ./apps/backplane/mix.exs
COPY apps/backplane_agent_runtime/mix.exs ./apps/backplane_agent_runtime/mix.exs
COPY apps/backplane_ai_protocol/mix.exs ./apps/backplane_ai_protocol/mix.exs
COPY apps/backplane_ai_protocol_testkit/mix.exs ./apps/backplane_ai_protocol_testkit/mix.exs
COPY apps/backplane_auth/mix.exs ./apps/backplane_auth/mix.exs
COPY apps/backplane_data_case/mix.exs ./apps/backplane_data_case/mix.exs
COPY apps/backplane_llama/mix.exs ./apps/backplane_llama/mix.exs
COPY apps/backplane_llama/c_src ./apps/backplane_llama/c_src
COPY apps/backplane_mcp/mix.exs ./apps/backplane_mcp/mix.exs
COPY apps/backplane_mcp_protocol/mix.exs ./apps/backplane_mcp_protocol/mix.exs
COPY apps/backplane_memory/mix.exs ./apps/backplane_memory/mix.exs
COPY apps/backplane_memory_contract/mix.exs ./apps/backplane_memory_contract/mix.exs
COPY apps/backplane_monitor/mix.exs ./apps/backplane_monitor/mix.exs
COPY apps/backplane_plugin_protocol/mix.exs ./apps/backplane_plugin_protocol/mix.exs
COPY apps/backplane_plugins/mix.exs ./apps/backplane_plugins/mix.exs
COPY apps/backplane_skill_protocol/mix.exs ./apps/backplane_skill_protocol/mix.exs
COPY apps/backplane_skills/mix.exs ./apps/backplane_skills/mix.exs
COPY apps/backplane_system/mix.exs ./apps/backplane_system/mix.exs
COPY apps/backplane_telemetry/mix.exs ./apps/backplane_telemetry/mix.exs
COPY apps/backplane_api/mix.exs apps/backplane_api/package.json ./apps/backplane_api/
COPY apps/backplane_admin/mix.exs apps/backplane_admin/package.json ./apps/backplane_admin/
COPY apps/day_ex/mix.exs ./apps/day_ex/mix.exs
COPY apps/math_ex/mix.exs ./apps/math_ex/mix.exs
COPY apps/relayixir/mix.exs ./apps/relayixir/mix.exs

RUN mix deps.get
RUN mix deps.compile
RUN mix npm.install --frozen
COPY . .
RUN bash scripts/set-version.sh "${VERSION}" all
RUN mix assets.deploy
RUN elixir -pa _build/prod/lib/jason/ebin scripts/verify_web_assets.exs \
    --export . /web-assets "${VCS_REF}" "${VERSION}"

# Nothing executable, compiled or native crosses the asset boundary.
FROM scratch AS web-assets
COPY --from=web-assets-builder /web-assets/ /

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

COPY mix.exs mix.lock package.json package-lock.json ./
COPY config ./config
COPY apps/backplane/mix.exs ./apps/backplane/mix.exs
COPY apps/backplane_agent_runtime/mix.exs ./apps/backplane_agent_runtime/mix.exs
COPY apps/backplane_ai_protocol/mix.exs ./apps/backplane_ai_protocol/mix.exs
COPY apps/backplane_ai_protocol_testkit/mix.exs ./apps/backplane_ai_protocol_testkit/mix.exs
COPY apps/backplane_auth/mix.exs ./apps/backplane_auth/mix.exs
COPY apps/backplane_data_case/mix.exs ./apps/backplane_data_case/mix.exs
COPY apps/backplane_llama/mix.exs ./apps/backplane_llama/mix.exs
COPY apps/backplane_llama/c_src ./apps/backplane_llama/c_src
COPY apps/backplane_mcp/mix.exs ./apps/backplane_mcp/mix.exs
COPY apps/backplane_mcp_protocol/mix.exs ./apps/backplane_mcp_protocol/mix.exs
COPY apps/backplane_memory/mix.exs ./apps/backplane_memory/mix.exs
COPY apps/backplane_memory_contract/mix.exs ./apps/backplane_memory_contract/mix.exs
COPY apps/backplane_monitor/mix.exs ./apps/backplane_monitor/mix.exs
COPY apps/backplane_plugin_protocol/mix.exs ./apps/backplane_plugin_protocol/mix.exs
COPY apps/backplane_plugins/mix.exs ./apps/backplane_plugins/mix.exs
COPY apps/backplane_skill_protocol/mix.exs ./apps/backplane_skill_protocol/mix.exs
COPY apps/backplane_skills/mix.exs ./apps/backplane_skills/mix.exs
COPY apps/backplane_system/mix.exs ./apps/backplane_system/mix.exs
COPY apps/backplane_telemetry/mix.exs ./apps/backplane_telemetry/mix.exs
COPY apps/backplane_api/mix.exs apps/backplane_api/package.json ./apps/backplane_api/
COPY apps/backplane_admin/mix.exs apps/backplane_admin/package.json ./apps/backplane_admin/
COPY apps/day_ex/mix.exs ./apps/day_ex/mix.exs
COPY apps/math_ex/mix.exs ./apps/math_ex/mix.exs
COPY apps/relayixir/mix.exs ./apps/relayixir/mix.exs

RUN mix deps.get
RUN mix deps.compile

COPY . .
RUN bash scripts/set-version.sh "${VERSION}" all

COPY --from=web-assets-builder /web-assets/apps/backplane_api/priv/static ./apps/backplane_api/priv/static
COPY --from=web-assets-builder /web-assets/apps/backplane_admin/priv/static ./apps/backplane_admin/priv/static
RUN mix backplane.pty.build
RUN mix release backplane --overwrite --version "${VERSION}" \
  && elixir -pa _build/prod/lib/jason/ebin scripts/verify_web_assets.exs \
    --release _build/prod/rel/backplane \
  && test -x "_build/prod/rel/backplane/lib/backplane_agent_runtime-${VERSION}/priv/bin/backplane-local-command-pty" \
  && "_build/prod/rel/backplane/lib/backplane_agent_runtime-${VERSION}/priv/bin/backplane-local-command-pty" --probe

RUN <<'VERIFY_RELEASE_VERSION'
elixir -e '
expected = hd(System.argv())
applications =
  for path <- Path.wildcard("_build/prod/rel/backplane/lib/backplane*-*/ebin/*.app") do
    {:ok, [{:application, app, metadata}]} = :file.consult(String.to_charlist(path))
    actual = to_string(Keyword.fetch!(metadata, :vsn))
    unless actual == expected do
      raise "assembled application version mismatch for #{app}: #{actual}, expected #{expected}"
    end
    app
  end
unless :backplane in applications and :backplane_admin in applications do
  raise "assembled Backplane applications are missing"
end
' "${VERSION}"
VERIFY_RELEASE_VERSION

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
    ffmpeg \
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
