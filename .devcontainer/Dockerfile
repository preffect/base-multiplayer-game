FROM mcr.microsoft.com/devcontainers/base:ubuntu

# System dependencies + locale
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    python3 \
    tmux \
    curl \
    locales \
    ripgrep \
    jq \
    imagemagick \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV TERM=xterm-256color

# Install Node 24 via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install pnpm globally
RUN npm install -g pnpm@10

# GitHub CLI (agents open PRs / update issues from inside the container; auth comes from the
# host's ~/.config/gh, which dev-container.sh / devcontainer.json bind-mount — see WORKFLOW.md)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/*

# Playwright MCP + Chromium (+ system libs), installed globally so every role can screenshot
# the running game headlessly without a network fetch at runtime. Chromium is installed by the
# playwright version bundled INSIDE @playwright/mcp, so the two can never mismatch.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN npm install -g @playwright/mcp@latest && \
    cd "$(npm root -g)/@playwright/mcp" && npx playwright install --with-deps chromium && \
    chmod -R a+rX /opt/playwright && rm -rf /var/lib/apt/lists/*

# Install Claude Code (as vscode user so it lands on their PATH)
USER vscode
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

# Copy tmux config
COPY .tmux.conf /tmp/.tmux.conf
RUN cp /tmp/.tmux.conf /root/.tmux.conf && \
    for user_home in /home/vscode /home/node; do \
      if [ -d "$user_home" ]; then \
        cp /tmp/.tmux.conf "$user_home/.tmux.conf" && \
        chown "$(stat -c '%U:%G' "$user_home")" "$user_home/.tmux.conf"; \
      fi; \
    done && \
    rm /tmp/.tmux.conf
