# Runbook

Everything below assumes a Docker **Swarm** with exactly one manager, and that
the runtime is pinned to that manager (`placement: node.role == manager` in the
stack file). Named volumes are node-local, so the pin is what keeps state.

---

## Installing on a fresh host

Follow these in order. Steps 0 and 1 are the ones people skip and then spend an
afternoon debugging.

### 0. Prerequisite: the Portainer Agent must be in cluster mode

**Only relevant if you deploy through Portainer.** Skip to step 1 if you deploy
by CLI.

This is the only stack in the environment that asks Docker to **create an
overlay network**. Every other stack attaches to a pre-existing
`external: true` network, which any node can do. Creating a network requires a
**manager**.

Portainer round-robins requests across its agents (`-H tcp://tasks.agent:9001`
is DNS-RR). If the agents have not formed a cluster, whichever agent answers
executes the request locally instead of forwarding it to a manager — so roughly
half of all deploys land on a worker and fail with:

    failed to create network <stack>_multica_runtime: Error response from daemon:
    This node is not a swarm manager.

The fix is one environment variable on the **agent** service of the Portainer
stack (see `stacks/portainer.yaml` in the `tuialat` repo):

```yaml
  agent:
    image: portainer/agent:sts
    environment:
      AGENT_CLUSTER_ADDR: tasks.agent
    deploy:
      mode: global
```

Redeploy the Portainer stack **by CLI, not from the Portainer UI** — you are
restarting Portainer itself, and from inside the UI the operation cuts off
halfway:

```bash
docker stack deploy -c stacks/portainer.yaml portainer
```

Verify the agents actually clustered — you want `serf: EventMemberJoin` lines
naming **both** nodes, and `Running in cluster mode`:

```bash
docker service logs portainer_agent --tail 80
docker service inspect portainer_agent \
  --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}'   # AGENT_CLUSTER_ADDR=tasks.agent
```

Also check **Settings → Environments → <environment> → URL** in Portainer. It
must be `tasks.agent:9001` (DNS round-robin over the agent tasks). A single node
IP, a node hostname, or a VIP-resolving name pins Portainer to one agent
forever — and it may not be the manager's.

### 1. Create the four Docker secrets

The stack declares all four as `external: true`, so **they must exist before the
first deploy** or it fails immediately. Create them once on the manager; they
are cluster-wide and shared by every stack that references them.

```bash
# Multica personal access token — Settings > API Tokens in the Multica UI.
printf '%s' '<multica-token>' | docker secret create multica_token -

# Git deploy/user key. Must have WRITE access — agents push branches.
# Must NOT have a passphrase; entrypoint.sh will tell you at boot if it does.
docker secret create git_ssh_key /path/to/id_ed25519

# Minted with `claude setup-token` on a machine that HAS a browser
# (requires a Pro/Max/Team/Enterprise plan). This is what removes the
# interactive `docker exec` login step entirely.
printf '%s' '<claude-oauth-token>' | docker secret create claude_oauth_token -

# OpenCode's built-in "openai" provider reads this from the environment.
printf '%s' '<openai-api-key>' | docker secret create openai_api_key -
```

`printf '%s'` (no `\n`) matters: a trailing newline inside a token secret is a
silent auth failure later. The SSH key is the exception — it needs its newlines,
which is why it is created from a file, and `entrypoint.sh` normalises CRLF and
the trailing newline on the way in.

Confirm: `docker secret ls` should list all four.

### 2. Get the build context onto the manager

The image is built **on the manager**, from this repo's `Dockerfile` and
`entrypoint.sh`. Those two files are the entire build context — nothing else in
the repo is used.

If the manager has GitHub access:

```bash
git clone git@github.com:sinapzia/multica-runtime.git /opt/multica-runtime
cd /opt/multica-runtime
```

If it does not (Portainer clones inside its own container, not onto the host —
so the manager typically has no GitHub credentials), copy the two files over by
SFTP/scp instead:

```bash
scp Dockerfile entrypoint.sh root@<manager>:/opt/multica-runtime/
```

Two things to get right here:

- **Copy into a clean, dedicated directory** — `/opt/multica-runtime`, not
  `/root` or your home. `docker build .` tars the *entire* directory and uploads
  it to the daemon as the build context; pointing it at a home directory ships
  everything in it, including `.ssh` and `.bash_history`.

  Scope of the damage if you already did this: this Dockerfile has exactly one
  `COPY`, and it names `entrypoint.sh` explicitly. There is no `COPY . .`, so
  **nothing else can reach an image layer** — the resulting image is identical
  either way. What you get is a slow build, a build cache holding a snapshot of
  the directory, and a trap waiting for the day someone adds a broad `COPY`.
  Move the files and `docker builder prune`; there is no need to rebuild or
  rotate anything. Verify rather than trust:

  ```bash
  docker history --no-trunc multica-runtime:<tag> | grep -i copy
  docker run --rm --entrypoint sh multica-runtime:<tag> -c 'ls -a /root /home/node'
  ```

  A `.dockerignore` would blunt this, but it is not a substitute for a clean
  directory — it only filters what the daemon receives, and only what you
  remembered to list.
- **Use binary mode**, not auto/ASCII. An SFTP client in auto mode rewrites
  `entrypoint.sh` to CRLF and the container then dies at boot with a
  `bad interpreter` error that looks like nothing you changed.

### 3. Build the image on the manager

```bash
cd /opt/multica-runtime
docker build -t multica-runtime:<tag> .
```

Verify before deploying — the image starts under tini + `entrypoint.sh`, so
`--entrypoint` is required or you get a daemon instead of a version string:

```bash
docker run --rm --entrypoint opencode multica-runtime:<tag> --version   # 1.18.23
docker run --rm --entrypoint claude   multica-runtime:<tag> --version   # 2.1.234
```

**Why on the manager, and why by CLI:**

- Swarm does **not** share an image store between nodes. The image has to exist
  on the node that will run the task, and `placement: node.role == manager`
  guarantees that node is the manager. No registry needed.
- Portainer's *Images → Build a new image* builds on **whichever node answers
  the request** — the same round-robin as step 0. You can end up with the image
  on the worker and the service on the manager, which then cannot find it.
  Building by CLI on the manager is deterministic.
- A registry would also solve this, and is the right answer if you ever run more
  than one manager. For an image rebuilt every few months it is not worth it.

### 4. Deploy the stack

**By CLI** (recommended — no routing involved at all):

```bash
export MULTICA_RUNTIME_IMAGE=multica-runtime:<tag>
export MULTICA_WORKSPACE_ID=<workspace-uuid>       # see below if you don't have it yet
docker stack deploy -c multica-runtime-stack.yml --resolve-image never multica
```

`docker stack deploy` does **not** read a `.env` file the way `docker compose`
does — the variables have to be exported in the shell.

`--resolve-image never` stops Docker from trying to look the tag up in a
registry to record its digest. Without it the deploy still succeeds, but prints
a `could not be accessed on a registry` warning that reads like a failure.

**Through Portainer** — Stacks → Add stack. **Both the web editor and a
git-backed stack work**, once step 0 is done; verified on this environment.
Pick whichever you prefer:

1. Name the stack **exactly** what you want the volume prefix to be — volumes
   are named `<stack>_<volume>`. Get it wrong and you come up with empty state.
2. Web editor: paste `multica-runtime-stack.yml` verbatim. Git: point it at this
   repo and the file path; the YAML then has to be committed to change it.
3. Stack environment variables: `MULTICA_RUNTIME_IMAGE` = your tag,
   `MULTICA_WORKSPACE_ID` = the workspace UUID.
4. Leave **"re-pull image" OFF** while the tag exists only in the manager's
   local image store. That toggle runs `docker pull`, which has nothing to pull
   from; Portainer has no equivalent of `--resolve-image never`. Turn it on only
   once you are pushing the image to a registry.
5. Deploy.

The one thing that is not reversible: Portainer cannot convert a git stack to a
web-editor stack in place. Switching later means deleting and recreating the
stack — which, because volumes are named `<stack>_<volume>`, is only safe if you
reuse the exact same stack name.

Historical note: deploys used to fail through the agent for both methods. That
was step 0 (`AGENT_CLUSTER_ADDR`), not the deploy method — it was originally
misdiagnosed as the git path being special, and it is not.

**First deploy, if you don't have the workspace UUID yet:** leave
`MULTICA_WORKSPACE_ID` unset, let it come up, then read the resolved UUID from
inside the container and redeploy with it pinned:

```bash
docker exec -it <container-id> multica workspace list --full-id
```

### 5. Verify

```bash
docker service ps multica_runtime --no-trunc      # Running, no restart loop
docker service logs multica_runtime --tail 80     # [entrypoint] lines, no WARNING
docker exec -it <container-id> ls /run/secrets/   # all four secrets present
multica runtime list --output json
```

`runtime list` should show **two** entries for this one container — the daemon
registers one runtime per agent CLI it detects:

```
<uuid>  Claude (<daemon-id>)    claude    online
<uuid>  Opencode (<daemon-id>)  opencode  online
```

If only the Claude one appears, the image you deployed predates OpenCode —
you deployed an old tag, or the build didn't actually run. Check
`docker exec -it <container-id> opencode --version`.

### 6. Bind agents

Nothing is bound to a new runtime automatically. Point an agent at one:

```bash
multica agent create --name "OpenCode Test" \
  --runtime-id <opencode-runtime-id> --model openai/<model>

multica agent update <agent-id> --runtime-id <runtime-id>
```

---

## Rebuilding the image

The agent CLIs live **inside the image**, not in the stack file — the stack only
says which image to run. Any change to `Dockerfile` or `entrypoint.sh`, and any
Claude Code / OpenCode version bump, needs a rebuild or the redeploy just brings
up the same binaries.

```bash
cd /opt/multica-runtime
git pull                                          # or re-copy the two files
docker build -t multica-runtime:<new-tag> .
```

Then update `MULTICA_RUNTIME_IMAGE` to the new tag and redeploy (step 4).

**Use a new tag every time.** Reusing one makes rollback impossible and the old
image is what the running container still needs — do not prune an image a
service is using, or it will not come back up after a restart.

---

## Blue/green: a second runtime alongside the current one

Useful for testing an image without touching a working runtime. The daemon
identity is parameterised, so this needs **no YAML edit** — only stack
environment variables:

| Variable | Default | Set it to |
|---|---|---|
| `MULTICA_DAEMON_ID` | `vps-runtime` | `vps-runtime-v2` |
| `MULTICA_AGENT_RUNTIME_NAME` | `VPS Runtime` | `VPS Runtime v2` |
| `MULTICA_RUNTIME_IMAGE` | `multica-runtime:latest` | the new tag |
| `MULTICA_WORKSPACE_ID` | *(unset)* | the workspace UUID |

**`MULTICA_DAEMON_ID` is not optional here.** Two daemons sharing an ID register
as the *same* runtime: both heartbeat the same row and both poll the same queue,
so a task meant for the old runtime can be claimed by the new one. That is a
race, not parallelism, and it breaks exactly the thing you were trying to keep
intact.

Deploy it under a different stack name (`multica-v2`). What is and isn't shared:

- **Secrets** — shared. They are `external`, cluster-wide.
- **Volumes** — new and empty (`multica-v2_multica_state`, …). That is fine:
  `entrypoint.sh` re-runs `multica login --token` and re-seeds `.claude.json`
  from the secrets on every boot, so a fresh stack comes up **already
  authenticated** with no interactive step. The one real cost is
  `multica_workspaces` starting empty — repo clones and task workdirs are gone,
  so the first task per repo is slower while it re-clones.
- **Network** — separate (`multica-v2_multica_runtime`). The old stack's network
  is untouched.
- **CPU/RAM** — *not* shared. Both containers land on the manager, 2 CPU / 4 GB
  each, next to the swarm control plane. Do not leave it that way indefinitely.

The stack name and daemon ID are effectively permanent — renaming means
redoing the whole migration. Runtime display names, however, are cosmetic and
changeable at any time:

```bash
multica runtime rename <runtime-id> --name "VPS Runtime (Claude)"
```

---

## Decommissioning a stack

In this order:

```bash
# 1. Move every agent off the old runtime FIRST.
multica agent update <agent-id> --runtime-id <new-runtime-id>

# 2. Remove the stack. Volumes survive this — keep them a few days as rollback.
docker stack rm <old-stack>

# 3. Only now remove any network the old stack owned.
docker network rm <old-stack>_multica_runtime

# 4. Delete the runtime records.
multica runtime delete <old-runtime-id>

# 5. Days later, once you're sure:
docker volume rm <old-stack>_multica_state <old-stack>_claude_state \
                 <old-stack>_opencode_state <old-stack>_multica_workspaces
```

`multica runtime delete` **refuses** while agents are still bound to it. That
refusal is the safety net — do not defeat it with `--cascade`, which unbinds the
agents *and cancels their queued tasks*.

If the old stack was git-based in Portainer, delete its entry in the Portainer UI
too, or it lingers as an orphan.

---

## Capacity

`MULTICA_DAEMON_MAX_CONCURRENT_TASKS` is set to `1`. The default is 20, and this
container runs on the manager — a runaway agent here doesn't just cost you the
runtime, it costs you the node that governs the cluster.

One slot means every agent queues behind every other, including both providers:
Claude and OpenCode share the same container and therefore the same pool. Raise
it to 2–3 if queueing becomes the bottleneck; split into a second stack only if
you genuinely need the two providers running concurrently.

---

## Claude Code login fallback

If the `claude_oauth_token` secret isn't set, log in interactively once
(credentials persist in the `claude_state` volume):

    docker exec -it <container-id> claude   # never with -u root

`-u root` writes the credentials to `/root/.claude`, outside the volume, and
they vanish on the next redeploy.

## Bumping the pinned Claude Code / OpenCode version

`CLAUDE_CODE_VERSION` (2.1.234) and `OPENCODE_VERSION` (1.18.23) in the
Dockerfile are pinned on purpose — both self-updaters are disabled, so the
version baked into the image is what runs until the next rebuild. To bump
either, change its default, rebuild with a new tag, redeploy.

The multica CLI is intentionally left on latest: the daemon auto-updates itself
at runtime by default (`MULTICA_DAEMON_AUTO_UPDATE`, unset in the stack file),
so pinning it in the image would only affect the first boot.

## OpenCode (OpenAI) support

Auth is the `openai_api_key` secret: `entrypoint.sh` exports it as
`OPENAI_API_KEY`, which OpenCode's built-in "openai" provider picks up from the
environment automatically — no `/connect` or `auth.json` step needed. The
multica binary never touches `OPENAI_API_KEY` itself; it is read by the
`opencode` CLI from the environment, which is why exporting it in the entrypoint
is the right place.

If a future OpenCode release stops auto-detecting the env var, fall back to:

    # one-time interactive login (never with -u root)
    docker exec -it <container-id> opencode auth login

or seed `~/.local/share/opencode/auth.json` by hand:

    { "openai": { "type": "api", "key": "<key>" } }

Either way, credentials persist in the `opencode_state` volume.

## Recovery

State lives in four node-local named volumes (`multica_state`, `claude_state`,
`opencode_state`, `multica_workspaces`) on the manager node. If that node is
lost, the volumes are lost with it — but because both `multica login` and the
Claude Code OAuth token are re-applied from secrets on every boot, redeploying
elsewhere does **not** require re-running any login step. What you actually lose
is the repo clone cache and task workdirs, which rebuild themselves.

The one thing that does not rebuild itself is the secrets. Keep them somewhere
you can get them back from.
