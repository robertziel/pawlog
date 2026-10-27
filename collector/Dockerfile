FROM rust:1.90-bookworm AS dev
RUN apt-get update && apt-get install -y --no-install-recommends cmake && rm -rf /var/lib/apt/lists/*
WORKDIR /src

FROM dev AS build
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/src/target \
    cargo build --release && cp target/release/collector /collector

FROM debian:bookworm-slim
COPY --from=build /collector /usr/local/bin/collector
USER nobody
ENTRYPOINT ["collector"]
