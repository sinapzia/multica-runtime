# Runbook

## Build

    docker build -t <registry>/multica-runtime:<tag> .

Push it, then set `MULTICA_RUNTIME_IMAGE=<registry>/multica-runtime:<tag>` as a
**stack-level** environment variable in Portainer (or export it in your shell) —
`docker stack deploy` does not read a `.env` file the way `docker compose` does.

## Deploy

    docker stack deploy -c multica-runtime-stack.yml --resolve-image never multica

Requires the `multica_token`, `git_ssh_key`, and `claude_oauth_token` Docker
secrets to already exist (`external: true`).

On the very first deploy, leave `MULTICA_WORKSPACE_ID` unset, then read the
resolved UUID from inside the running container:

    docker exec -it <container-id> multica workspace list --full-id

Set that as a stack environment variable and redeploy so it's pinned going
forward.

## Claude Code login fallback

If the `claude_oauth_token` secret isn't set, log in interactively once
(credentials persist in the `claude_state` volume):

    docker exec -it <container-id> claude   # never with -u root

## Bumping pinned versions

`CLAUDE_CODE_VERSION` and `MULTICA_CLI_VERSION` in the Dockerfile are pinned
on purpose — see the comments above each `ARG`. To bump either, change the
default, rebuild, and redeploy. There is no auto-update.

## Recovery

State lives in three node-local named volumes (`multica_state`, `claude_state`,
`multica_workspaces`) on the manager node. If that node is lost, the volumes
are lost with it — redeploying elsewhere means re-running the login steps
above from scratch.
