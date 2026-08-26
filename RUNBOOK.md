# Runbook

## Build

    docker build -t <registry>/multica-runtime:<tag> .

Push it, then set `MULTICA_RUNTIME_IMAGE=<registry>/multica-runtime:<tag>` as a
**stack-level** environment variable in Portainer (or export it in your shell) —
`docker stack deploy` does not read a `.env` file the way `docker compose` does.

## Deploy

    docker stack deploy -c multica-runtime-stack.yml --resolve-image never multica

Requires the `multica_token`, `git_ssh_key`, `claude_oauth_token`, and
`openai_api_key` Docker secrets to already exist (`external: true`).

On the very first deploy, leave `MULTICA_WORKSPACE_ID` unset, then read the
resolved UUID from inside the running container:

    docker exec -it <container-id> multica workspace list --full-id

Set that as a stack environment variable and redeploy so it's pinned going
forward.

## Claude Code login fallback

If the `claude_oauth_token` secret isn't set, log in interactively once
(credentials persist in the `claude_state` volume):

    docker exec -it <container-id> claude   # never with -u root

## Bumping the pinned Claude Code / OpenCode version

`CLAUDE_CODE_VERSION` and `OPENCODE_VERSION` in the Dockerfile are pinned
on purpose (see the comments above each `ARG`) — both self-updaters are
disabled, so the version baked into the image is what runs until the next
rebuild. To bump either, change its default, rebuild, and redeploy.

The multica CLI is intentionally left on latest: the daemon auto-updates
itself at runtime by default (`MULTICA_DAEMON_AUTO_UPDATE`, unset in
multica-runtime-stack.yml), so pinning it in the image would only affect
the first boot.

## OpenCode (OpenAI) support

OpenCode shares this daemon/container with Claude Code — same
`MULTICA_DAEMON_MAX_CONCURRENT_TASKS` pool, so tasks from either provider
queue sequentially rather than running in true parallel. That's expected;
split into a second stack/service only if you actually need both to run
concurrently.

Auth is the `openai_api_key` secret: entrypoint.sh exports it as
`OPENAI_API_KEY`, which OpenCode's built-in "openai" provider picks up from
the environment automatically — no `/connect` or `auth.json` step needed.

If a future OpenCode release stops auto-detecting the env var, fall back to
one of:

    # one-time interactive login (never with -u root)
    docker exec -it <container-id> opencode auth login

or seed `~/.local/share/opencode/auth.json` by hand:

    { "openai": { "type": "api", "key": "<key>" } }

Either way, credentials persist in the `opencode_state` volume.

After deploying, confirm the daemon picked up the new provider with
`multica runtime list --output json` (a second entry should appear with
`"provider": "opencode"`), then bind an agent to it with
`multica agent create --runtime-id <opencode-runtime-id> --model openai/<model>`.

## Recovery

State lives in four node-local named volumes (`multica_state`, `claude_state`,
`opencode_state`, `multica_workspaces`) on the manager node. If that node is
lost, the volumes are lost with it — redeploying elsewhere means re-running
the login steps above from scratch.
