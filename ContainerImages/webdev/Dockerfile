FROM alpine:3.19

RUN apk add --no-cache \
    bash curl git openssh-client ripgrep fd jq tree less vim \
    tar gzip ca-certificates shadow \
    nodejs npm

# Web development tools
RUN npm install -g \
    npm@latest \
    vite \
    create-vite \
    tailwindcss \
    postcss \
    autoprefixer \
    prettier \
    eslint \
    typescript \
    ts-node \
    serve \
    http-server

# Yarn and pnpm
RUN npm install -g yarn pnpm

RUN mkdir -p /workspace && \
    git config --global init.defaultBranch main

RUN echo 'export PS1="\[\033[1;32m\]pocketdev\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]# "' >> /root/.bashrc && \
    echo 'export TERM=xterm-256color' >> /root/.bashrc && \
    echo 'cd /workspace' >> /root/.bashrc && \
    echo 'echo "PocketDev Web Development Environment"' >> /root/.bashrc && \
    echo 'echo "Node.js $(node -v) | Vite | Tailwind CSS"' >> /root/.bashrc

WORKDIR /workspace
CMD ["/bin/bash", "-l"]
