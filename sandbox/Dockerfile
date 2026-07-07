FROM swift:6.3-noble
LABEL org.opencontainers.image.source="https://github.com/philliplakis/open-box"
ENV DEBIAN_FRONTEND=noninteractive
ENV BUN_INSTALL=/opt/bun
ENV PATH="${BUN_INSTALL}/bin:${PATH}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gpg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        bash build-essential cargo cmake file findutils git gh golang-go jq less \
        nodejs openssh-client patch pkg-config procps python3 python3-pip \
        python3-venv ripgrep rustc sqlite3 sudo tar tree unzip vim wget zip zsh \
    && npm install -g @anthropic-ai/claude-code @google/gemini-cli @openai/codex global-agent \
    && curl -fsSL https://bun.sh/install | bash -s -- bun-v1.3.14 \
    && curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/*

RUN mkdir -p /workspace /run/openbox

WORKDIR /workspace
