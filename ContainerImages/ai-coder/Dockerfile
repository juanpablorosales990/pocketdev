FROM alpine:3.19 AS base

# System packages
RUN apk add --no-cache \
    bash \
    curl \
    git \
    openssh-client \
    ripgrep \
    fd \
    jq \
    tree \
    less \
    vim \
    tar \
    gzip \
    ca-certificates \
    shadow

# Node.js 22 LTS
RUN apk add --no-cache nodejs npm && \
    npm install -g npm@latest

# Claude Code (AI coding assistant)
RUN npm install -g @anthropic-ai/claude-code

# Development tools
RUN npm install -g \
    typescript \
    ts-node \
    prettier \
    eslint

# Git configuration
RUN git config --global init.defaultBranch main && \
    git config --global core.editor vim && \
    git config --global pull.rebase false

# Create workspace
RUN mkdir -p /workspace

# Shell configuration
RUN echo 'export PS1="\[\033[1;32m\]pocketdev\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]# "' >> /root/.bashrc && \
    echo 'export TERM=xterm-256color' >> /root/.bashrc && \
    echo 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /root/.bashrc && \
    echo 'cd /workspace' >> /root/.bashrc && \
    echo 'echo "PocketDev AI Coder Environment"' >> /root/.bashrc && \
    echo 'echo "Node.js $(node -v) | npm $(npm -v) | git $(git --version | cut -d\" \" -f3)"' >> /root/.bashrc && \
    echo 'echo "Type: claude to start Claude Code"' >> /root/.bashrc

# Signal readiness
RUN echo '#!/bin/sh' > /usr/local/bin/pocketdev-init && \
    echo 'echo "pocketdev-ready" > /dev/console 2>/dev/null || true' >> /usr/local/bin/pocketdev-init && \
    echo 'exec /bin/bash -l' >> /usr/local/bin/pocketdev-init && \
    chmod +x /usr/local/bin/pocketdev-init

WORKDIR /workspace
CMD ["/usr/local/bin/pocketdev-init"]
