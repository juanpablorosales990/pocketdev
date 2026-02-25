FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git openssh-client ripgrep fd-find jq tree less vim \
    tar gzip ca-certificates \
    nodejs npm \
    python3 python3-pip python3-venv \
    postgresql postgresql-client \
    redis-server redis-tools \
    nginx \
    && rm -rf /var/lib/apt/lists/*

# Node.js tools
RUN npm install -g npm@latest typescript ts-node prettier eslint vite

# Python tools
RUN pip3 install --break-system-packages \
    flask fastapi uvicorn django sqlalchemy alembic pytest

# PostgreSQL setup
RUN echo "local all all trust" > /etc/postgresql/15/main/pg_hba.conf && \
    echo "host all all 0.0.0.0/0 trust" >> /etc/postgresql/15/main/pg_hba.conf

RUN mkdir -p /workspace && \
    git config --global init.defaultBranch main

# Startup script that launches services
RUN echo '#!/bin/bash' > /usr/local/bin/pocketdev-init && \
    echo 'pg_ctlcluster 15 main start 2>/dev/null || true' >> /usr/local/bin/pocketdev-init && \
    echo 'redis-server --daemonize yes 2>/dev/null || true' >> /usr/local/bin/pocketdev-init && \
    echo 'echo "pocketdev-ready"' >> /usr/local/bin/pocketdev-init && \
    echo 'exec /bin/bash -l' >> /usr/local/bin/pocketdev-init && \
    chmod +x /usr/local/bin/pocketdev-init

RUN echo 'export PS1="\[\033[1;32m\]pocketdev\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]# "' >> /root/.bashrc && \
    echo 'export TERM=xterm-256color' >> /root/.bashrc && \
    echo 'cd /workspace' >> /root/.bashrc && \
    echo 'echo "PocketDev Full Stack Environment"' >> /root/.bashrc && \
    echo 'echo "Node.js | Python | PostgreSQL | Redis"' >> /root/.bashrc

WORKDIR /workspace
CMD ["/usr/local/bin/pocketdev-init"]
