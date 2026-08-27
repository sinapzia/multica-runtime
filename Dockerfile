FROM node:20-slim

# Runtime image for a Multica agent runtime: the Multica daemon, the provider
# CLIs it drives (Claude Code, OpenCode), and gh for opening PRs. Deliberately
# NOT the Multica server — this box only executes tasks handed to it by
# Multica Cloud.

ARG TZ=UTC
ENV TZ="$TZ"

# Pinned. `latest` means every rebuild is a different agent, and a bad
# Claude Code release becomes an outage you cannot roll back to. To bump,
# change this default, rebuild, and redeploy — see RUNBOOK.md.
ARG CLAUDE_CODE_VERSION=2.1.234

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  openssh-client \
  tini \
  procps \
  less \
  ripgrep \
  jq \
  # node:20-slim ships no /usr/share/zoneinfo, so TZ is silently ignored and
  # everything logs in UTC. This is the fix.
  tzdata \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Claude Code, installed globally into a root-owned prefix the node user can read.
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
RUN mkdir -p /usr/local/share/npm-global && \
  npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && \
  claude --version

# The prefix is root-owned and the container runs as node, so every
# self-update attempt fails and noises up the logs. Version is a build input.
ENV DISABLE_AUTOUPDATER=1

# OpenCode, the OpenAI-backed sibling provider. Same rationale as Claude Code
# above: pinned on purpose so a rebuild doesn't silently change which agent
# runs, and self-update is disabled for the same root-owned-prefix reason.
ARG OPENCODE_VERSION=1.18.23
RUN npm install -g opencode-ai@${OPENCODE_VERSION} && \
  opencode --version
ENV OPENCODE_DISABLE_AUTOUPDATE=1

# Multica CLI. Left on latest, unlike Claude Code above — the daemon
# auto-updates itself in runtime by default (MULTICA_DAEMON_AUTO_UPDATE,
# see multica-runtime-stack.yml), so whatever ships in the image only
# matters for the first boot; pinning it here would just be cosmetic.
# MULTICA_BIN_DIR keeps the installer out of its sudo path.
RUN curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh \
  | MULTICA_BIN_DIR=/usr/local/bin bash \
  && multica --version

# GitHub CLI, so agents can open PRs directly (`gh pr create`) instead of just
# pushing a branch — step 7 of the Backend Engineer workflow. Not pinned, same
# as the other apt packages above (git, jq, ...): unlike Claude Code/OpenCode,
# a `gh` version bump does not change agent behavior, just the CLI it shells
# out to.
RUN mkdir -p -m 755 /etc/apt/keyrings \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && gh --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# State directories. All three are volume mount points in the stack file —
# anything written here without a volume is lost on redeploy.
#
# Creating AND chowning them here is load-bearing: an empty named volume
# inherits the ownership of the image directory it covers. Drop this and the
# volumes come up root-owned and the daemon cannot write to them.
RUN mkdir -p /home/node/.multica /home/node/.claude /home/node/multica_workspaces /home/node/.ssh \
    /home/node/.local/share/opencode /home/node/.config/opencode && \
  chmod 700 /home/node/.ssh && \
  chown -R node:node /home/node

USER node
WORKDIR /home/node

ENV HOME=/home/node

# Must match the claude_state volume mount path exactly. Claude Code keeps the
# OAuth account and per-project trust in .claude.json, which lives OUTSIDE
# ~/.claude by default — setting this pulls it into the volume.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude
ENV MULTICA_WORKSPACES_ROOT=/home/node/multica_workspaces

# `multica daemon status` talks to the local daemon directly — no port to
# configure — and exits non-zero if it's not reachable, so a hung daemon
# gets caught even though the container process itself is still alive.
HEALTHCHECK --interval=60s --timeout=10s --start-period=90s --retries=3 \
  CMD multica daemon status >/dev/null 2>&1 || exit 1

# tini reaps the agent processes Claude Code spawns; without it they pile up as
# zombies in a long-lived daemon container.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
