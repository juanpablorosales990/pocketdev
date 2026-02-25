FROM alpine:3.19

RUN apk add --no-cache \
    bash curl wget git openssh-client ripgrep fd jq tree less vim \
    tar gzip ca-certificates shadow \
    docker-cli docker-compose \
    python3 py3-pip

# kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/arm64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/

# Terraform
RUN wget -q https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_arm64.zip && \
    unzip terraform_1.7.0_linux_arm64.zip -d /usr/local/bin/ && \
    rm terraform_1.7.0_linux_arm64.zip

# AWS CLI
RUN pip3 install --break-system-packages awscli

# Helm
RUN curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# k9s
RUN wget -q https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_arm64.tar.gz && \
    tar -xzf k9s_Linux_arm64.tar.gz -C /usr/local/bin/ k9s && \
    rm k9s_Linux_arm64.tar.gz

RUN mkdir -p /workspace && \
    git config --global init.defaultBranch main

RUN echo 'export PS1="\[\033[1;32m\]pocketdev\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]# "' >> /root/.bashrc && \
    echo 'export TERM=xterm-256color' >> /root/.bashrc && \
    echo 'cd /workspace' >> /root/.bashrc && \
    echo 'echo "PocketDev DevOps Environment"' >> /root/.bashrc && \
    echo 'echo "Docker CLI | kubectl | Terraform | AWS CLI | Helm"' >> /root/.bashrc

WORKDIR /workspace
CMD ["/bin/bash", "-l"]
