# syntax=docker/dockerfile:1.7
#
# The SDD workbench base: what the agents need in every project, whatever its
# stacks. A project's dev container is this image plus the add-ons its
# codebases ask for (features/), composed by `python3 tools/sdd compose`.
#
# It holds tools only: never a secret, never a product's code, and never
# Claude Code itself. The CLI lives on its own volume (/claude-code) and
# updates itself there, so neither a rebuild nor a newer base moves it
# (sdd-workbench-init, claude-code-ensure).

ARG DEBIAN=bookworm
FROM debian:${DEBIAN}-slim

ARG USERNAME=dev
ARG USER_UID=1000
# The current Node.js LTS. One Node per container (F32): no nvm, no second
# copy from a feature. A codebase states the range it needs (`requires`),
# and compose checks it against this.
ARG NODE_VERSION=26.13.1
# The Playwright whose Chromium the framework's mockup rendering and design
# fidelity use when no client codebase installs one (sdd-workbench-init).
ARG PLAYWRIGHT_VERSION=1.65.1
ARG ZSH_IN_DOCKER_VERSION=1.2.0
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    DEVCONTAINER=true \
    SDD_WORKBENCH=1

# ─── System tools ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg2 git git-lfs openssh-client \
      sudo less procps psmisc lsof iproute2 netcat-openbsd socat \
      zsh fzf jq ripgrep unzip xz-utils zstd \
      nano vim-tiny man-db bc \
      libatomic1 \
      python3 \
 && rm -rf /var/lib/apt/lists/*

# ─── GitHub CLI ───────────────────────────────────────────────────────
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# ─── Node.js, from nodejs.org's own tarball, checksum-verified ────────
RUN set -eux; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) arch=x64 ;; arm64) arch=arm64 ;; *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    base="https://nodejs.org/dist/v${NODE_VERSION}"; \
    file="node-v${NODE_VERSION}-linux-${arch}.tar.xz"; \
    curl -fsSLO "$base/$file"; \
    curl -fsSL "$base/SHASUMS256.txt" | grep " $file\$" | sha256sum -c -; \
    tar -xJf "$file" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "$file"; \
    node --version; npm --version
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=/home/${USERNAME}/.local/bin:/usr/local/share/npm-global/bin:$PATH

# ─── Chromium's runtime libraries (headless; no X server) ─────────────
# The set `playwright install-deps chromium` reports for Debian 12. The
# browser itself goes on the /playwright-browsers volume at first start.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcups2 libxkbcommon0 \
      libasound2 libgbm1 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
      libnspr4 libnss3 libdrm2 libpango-1.0-0 libcairo2 libxshmfence1 \
      fonts-liberation fonts-noto-color-emoji \
 && rm -rf /var/lib/apt/lists/*
ENV PLAYWRIGHT_BROWSERS_PATH=/playwright-browsers \
    SDD_PLAYWRIGHT_VERSION=${PLAYWRIGHT_VERSION}

# ─── The non-root user and the volumes' mount points ──────────────────
# Docker seeds an empty named volume from the image path it is mounted
# over, ownership included, so each mount point is created here as `dev`.
RUN groupadd --gid ${USER_UID} ${USERNAME} \
 && useradd --uid ${USER_UID} --gid ${USER_UID} -m -s /bin/zsh ${USERNAME} \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
 && chmod 0440 /etc/sudoers.d/${USERNAME} \
 && mkdir -p /workspace /claude-config /claude-code /commandhistory \
             /playwright-browsers /usr/local/share/npm-global \
 && touch /commandhistory/.zsh_history /commandhistory/.bash_history \
 && chown -R ${USERNAME}:${USERNAME} /workspace /claude-config /claude-code \
             /commandhistory /playwright-browsers /usr/local/share/npm-global \
 && install -d -o ${USERNAME} -g ${USERNAME} -m 0700 /home/${USERNAME}/.ssh \
 && install -o ${USERNAME} -g ${USERNAME} -m 0600 /dev/null /home/${USERNAME}/.ssh/known_hosts \
 && install -d -o ${USERNAME} -g ${USERNAME} /home/${USERNAME}/.local \
      /home/${USERNAME}/.local/bin /home/${USERNAME}/.local/share /home/${USERNAME}/.local/state \
 && ln -s /claude-code /home/${USERNAME}/.local/share/claude \
 && chown -h ${USERNAME}:${USERNAME} /home/${USERNAME}/.local/share/claude
ENV CLAUDE_CONFIG_DIR=/claude-config

USER ${USERNAME}
WORKDIR /workspace

# The slow downloads first, so a change to the workbench's own scripts below
# does not fetch them again.
# ─── Plannotator (the wrapper goes over it below) ─────────────────────
# The loop turns it off in every unattended session (F71); people use it.
RUN curl -fsSL https://plannotator.ai/install.sh | bash

# ─── Shell ────────────────────────────────────────────────────────────
ENV SHELL=/bin/zsh EDITOR=nano VISUAL=nano
RUN sh -c "$(wget -qO- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
      -p git -p fzf \
      -a "export HISTFILE=/commandhistory/.zsh_history" \
      -a "setopt INC_APPEND_HISTORY" \
      -x

# ─── The workbench's own scripts ──────────────────────────────────────
USER root
COPY rootfs/ /
# What this image provides, by tool: `sdd compose` checks each codebase's
# `requires` against it (test/base/test.sh holds it true).
COPY provides.json /usr/local/share/sdd-workbench/provides.json
RUN chmod 0755 /usr/local/bin/* \
 && install -m 0755 /usr/local/share/sdd-workbench/host-open/host-open /usr/local/bin/host-open
USER ${USERNAME}
RUN sdd-workbench-plannotator-wrapper

# Every start: Claude Code on its volume, the browser on its volume, then
# whatever the container was asked to run (sleep infinity, a shell).
ENTRYPOINT ["/usr/local/bin/sdd-workbench-init"]
CMD ["sleep", "infinity"]
