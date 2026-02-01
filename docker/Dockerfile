FROM python:3.11-slim

LABEL maintainer="heartbeat"
LABEL description="FreeTAKServer for Heartbeat TAK deployment"

RUN apt-get update && apt-get install -y --no-install-recommends \
        libxml2-dev \
        libxslt1-dev \
        gcc \
        qrencode \
    && rm -rf /var/lib/apt/lists/*

# Pin opentelemetry-sdk to avoid BatchSpanProcessor property setter bug
# in newer versions, then install FTS
RUN pip install --no-cache-dir \
        'opentelemetry-sdk<1.28' \
        'opentelemetry-api<1.28' \
    && pip install --no-cache-dir FreeTAKServer

RUN mkdir -p /opt/fts/data \
             /opt/fts/certs \
             /opt/fts/logs \
             /opt/fts/ExCheck/template \
             /opt/fts/ExCheck/checklist \
             /opt/fts/FreeTAKServerDataPackages

COPY FTSConfig.yaml /opt/FTSConfig.yaml
COPY FTSConfig.yaml /opt/fts/FTSConfig.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV FTS_CONFIG_PATH=/opt/fts/FTSConfig.yaml

EXPOSE 8087 8089 8443 19023

WORKDIR /opt/fts

ENTRYPOINT ["/entrypoint.sh"]
