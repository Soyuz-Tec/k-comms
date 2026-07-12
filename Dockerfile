ARG ELIXIR_IMAGE=elixir:1.20.1-otp-29-slim
ARG NODE_IMAGE=node:22-bookworm-slim
ARG RUNTIME_IMAGE=debian:trixie-slim

FROM ${ELIXIR_IMAGE} AS beam-base
ENV LANG=C.UTF-8
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      libssl-dev \
      postgresql-client \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
RUN mix local.hex --force && mix local.rebar --force

FROM beam-base AS dev
ENV MIX_ENV=dev
COPY . .
RUN mix deps.get --check-locked
CMD ["mix", "phx.server"]

FROM ${NODE_IMAGE} AS web-build
WORKDIR /workspace/clients/web
COPY clients/web/package.json clients/web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY clients/web/ ./
RUN npm run build

FROM beam-base AS build
ENV MIX_ENV=prod
COPY . .
RUN mix deps.get --only prod --check-locked
COPY --from=web-build /workspace/clients/web/dist/ /workspace/apps/comms_web/priv/static/app/
RUN mix compile --warnings-as-errors \
    && mix release k_comms

# Keep the release OS aligned with the current official Elixir slim image.
# The previous Bookworm runtime could not run ERTS built on Trixie (GLIBC_2.38).
FROM ${RUNTIME_IMAGE} AS runtime
ENV LANG=C.UTF-8 \
    HOME=/tmp \
    PORT=4000 \
    K_COMMS_ROLE=all \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      libncurses6 \
      libsctp1 \
      libstdc++6 \
      openssl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 kcomms \
    && useradd --uid 10001 --gid 10001 --no-log-init --create-home --home-dir /home/kcomms kcomms
WORKDIR /app
COPY --from=build --chown=10001:10001 /workspace/_build/prod/rel/k_comms/ ./
USER 10001:10001
EXPOSE 4000
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=6 \
  CMD curl --fail --silent --show-error "http://127.0.0.1:${PORT:-4000}/health/live" >/dev/null || exit 1
ENTRYPOINT ["/app/bin/k_comms"]
CMD ["start"]
