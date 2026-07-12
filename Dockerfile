ARG ELIXIR_IMAGE=elixir:1.20.1-otp-29-slim
FROM ${ELIXIR_IMAGE} AS base
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates libssl-dev postgresql-client && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
RUN mix local.hex --force && mix local.rebar --force
FROM base AS dev
ENV MIX_ENV=dev
COPY . .
RUN mix deps.get
CMD ["mix", "phx.server"]
FROM base AS build
ENV MIX_ENV=prod
COPY . .
RUN mix deps.get --only prod && mix compile && mix release k_comms
FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends openssl libstdc++6 ncurses-base locales ca-certificates && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8
WORKDIR /app
RUN useradd --system --create-home --home-dir /app kcomms
COPY --from=build --chown=kcomms:kcomms /workspace/_build/prod/rel/k_comms ./
USER kcomms
ENTRYPOINT ["/app/bin/k_comms"]
CMD ["start"]
