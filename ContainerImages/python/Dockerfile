FROM alpine:3.19

RUN apk add --no-cache \
    bash curl git openssh-client ripgrep fd jq tree less vim \
    tar gzip ca-certificates shadow \
    python3 python3-dev py3-pip py3-virtualenv \
    gcc musl-dev linux-headers

# Python tools
RUN pip3 install --break-system-packages \
    jupyter \
    ipython \
    numpy \
    pandas \
    matplotlib \
    requests \
    httpx \
    flask \
    fastapi \
    uvicorn \
    pytest \
    black \
    ruff \
    mypy

RUN mkdir -p /workspace && \
    git config --global init.defaultBranch main

RUN echo 'export PS1="\[\033[1;32m\]pocketdev\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]# "' >> /root/.bashrc && \
    echo 'export TERM=xterm-256color' >> /root/.bashrc && \
    echo 'cd /workspace' >> /root/.bashrc && \
    echo 'echo "PocketDev Python Environment"' >> /root/.bashrc && \
    echo 'echo "Python $(python3 --version | cut -d\" \" -f2) | Jupyter | NumPy | Pandas"' >> /root/.bashrc

WORKDIR /workspace
CMD ["/bin/bash", "-l"]
