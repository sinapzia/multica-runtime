#!/usr/bin/env bash
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Git identity and credentials
# ---------------------------------------------------------------------------
# Agents check out repos and push branches using THIS container's git
# credentials — linking a repo in the Multica UI does not deliver the code.
if [ -f /run/secrets/git_ssh_key ]; then
  log "Installing git SSH key from secret..."

  # Do NOT copy the secret verbatim. When the secret is pasted into a textarea
  # (Portainer, most CI UIs) it commonly arrives with CRLF line endings or with
  # the trailing newline stripped, and OpenSSH rejects both with an unhelpful
  # "error in libcrypto". Normalise: strip CR, guarantee exactly one trailing
  # newline. $(cat) drops trailing newlines, printf puts exactly one back.
  umask 077
  printf '%s\n' "$(cat /run/secrets/git_ssh_key)" | tr -d '\r' > "$HOME/.ssh/id_ed25519"
  chmod 600 "$HOME/.ssh/id_ed25519"

  # Fail here with a readable message rather than inside the first git clone.
  if ssh-keygen -y -f "$HOME/.ssh/id_ed25519" >/dev/null 2>&1; then
    log "SSH key parsed OK."
  else
    log "ERROR: the git_ssh_key secret is not a valid private key."
    log "ERROR: re-create it — a passphrase-protected key will also fail here."
  fi

  # Pre-seed known_hosts so the first clone does not hang on a host prompt.
  : > "$HOME/.ssh/known_hosts"
  chmod 600 "$HOME/.ssh/known_hosts"
  for host in ${GIT_SSH_KNOWN_HOSTS:-github.com}; do
    ssh-keyscan -t rsa,ecdsa,ed25519 "$host" >> "$HOME/.ssh/known_hosts" 2>/dev/null \
      || log "WARNING: could not scan host keys for $host"
  done

  # Fail loudly at boot rather than silently inside the first agent task.
  # A deploy key with read-only access clones fine and fails only on push,
  # which surfaces as a confusing agent error an hour later.
  for host in ${GIT_SSH_KNOWN_HOSTS:-github.com}; do
    if ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes "git@${host}" 2>&1 \
        | grep -qiE 'success|authenticated'; then
      log "git SSH auth OK against ${host}."
    else
      log "WARNING: git SSH auth to ${host} did not confirm. Agents may fail to clone or push."
    fi
  done
else
  log "No git_ssh_key secret mounted — agents will only reach public repos over HTTPS."
fi

git config --global user.name  "${GIT_AUTHOR_NAME:-Multica Agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-agent@localhost}"
git config --global --add safe.directory '*'

# ---------------------------------------------------------------------------
# Multica authentication
# ---------------------------------------------------------------------------
# Browser OAuth cannot call back into a Swarm task, so authenticate with a
# personal access token from Settings > API Tokens.
#
# This runs on EVERY boot, unconditionally. The old "skip if auth status is
# already OK" shortcut meant that rotating the secret and force-updating the
# service did nothing: the stale-but-still-valid token in the state volume
# kept winning until it expired.
if [ -f /run/secrets/multica_token ]; then
  log "Logging in to Multica with the token secret..."
  multica login --token "$(cat /run/secrets/multica_token)" \
    || log "WARNING: multica login failed — check the token secret has not expired."
else
  log "WARNING: no multica_token secret mounted."
fi

# Token login does not clearly document workspace auto-discovery (the browser
# flow does). Pin MULTICA_WORKSPACE_ID in the stack and log what we resolved.
if [ -n "${MULTICA_WORKSPACE_ID:-}" ]; then
  log "Workspace pinned to ${MULTICA_WORKSPACE_ID}."
else
  log "WARNING: MULTICA_WORKSPACE_ID not set — relying on token login to discover workspaces."
  multica workspace list 2>/dev/null || log "WARNING: could not list workspaces."
fi

# ---------------------------------------------------------------------------
# Claude Code authentication
# ---------------------------------------------------------------------------
# Preferred path: a long-lived OAuth token minted on a machine that HAS a
# browser, with `claude setup-token` (requires Pro/Max/Team/Enterprise).
# Ship it as a docker secret and the interactive `docker exec` step disappears
# entirely — along with the dependency on claude_state surviving forever.
if [ -f /run/secrets/claude_oauth_token ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_oauth_token)"
  log "Claude Code will authenticate with the OAuth token secret."

  # Headless Claude Code still wants the onboarding flag or it opens a wizard.
  # Seed it once; never overwrite a real config.
  if [ ! -f "$CLAUDE_CONFIG_DIR/.claude.json" ]; then
    log "Seeding $CLAUDE_CONFIG_DIR/.claude.json with the onboarding flag..."
    printf '{"hasCompletedOnboarding":true}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
    chmod 600 "$CLAUDE_CONFIG_DIR/.claude.json"
  fi

# Fallback path: the one-time interactive login.
#
#   docker exec -it <container-id> claude      # NEVER with -u root
#
# The daemon starts either way: it will register as a runtime and then fail
# individual tasks, which is a far clearer symptom than refusing to boot.
elif [ -z "$(ls -A "$CLAUDE_CONFIG_DIR" 2>/dev/null)" ]; then
  log "WARNING: $CLAUDE_CONFIG_DIR is empty — Claude Code is not logged in yet."
  log "WARNING: run 'docker exec -it <container-id> claude' ON THE PINNED NODE to complete login."
  log "WARNING: do not pass -u root — credentials would land in /root/.claude and be lost."
else
  log "Claude Code credentials found in $CLAUDE_CONFIG_DIR."
fi

# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------
# --foreground is what makes this a well-behaved container process: the default
# backgrounds the daemon, which would exit the container immediately.
log "Starting Multica daemon as runtime '${MULTICA_AGENT_RUNTIME_NAME:-Local Agent}'..."
exec multica daemon start --foreground
