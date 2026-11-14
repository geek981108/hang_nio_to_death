FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        postgresql postgresql-client ca-certificates libpq5 jq python3 \
    && rm -rf /var/lib/apt/lists/*

COPY nio-swap-history-backend /usr/local/bin/nio-swap-history-backend
COPY proxy.py /proxy.py
COPY www /www
COPY run.sh /run.sh
RUN chmod a+x /run.sh /usr/local/bin/nio-swap-history-backend

CMD ["/run.sh"]
