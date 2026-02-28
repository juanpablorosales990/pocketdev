FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc-aarch64-linux-gnu bc flex bison \
    libssl-dev libelf-dev curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
