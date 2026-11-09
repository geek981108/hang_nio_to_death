FROM rust:1.90-bookworm AS builder
RUN apt-get update && apt-get install --yes --no-install-recommends libpq-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Cargo.toml Cargo.lock* ./
COPY pg_migrations ./pg_migrations
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home app
COPY --from=builder /app/target/release/nio-swap-history-backend /usr/local/bin/nio-swap-history-backend
USER app
ENV BIND_ADDR=0.0.0.0:8080 \
    DATABASE_URL=postgres://localhost/nio_swap_history
EXPOSE 8080
ENTRYPOINT ["nio-swap-history-backend"]
