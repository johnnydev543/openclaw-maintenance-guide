# OpenClaw NAS Maintenance Guide (English)

This guide documents a security-focused OpenClaw deployment:

```text
Reverse proxy
  -> host-native OpenClaw Gateway (dedicated non-root user)
  -> Docker sandbox containers
  -> agent tools and shell commands
```

The Gateway runs natively on the host. All agent command execution stays in a sandbox image. Credentials remain in the Gateway's protected state and are not baked into images or mounted into sandboxes.

## Operating model

- Run the Gateway as a dedicated `openclaw` user with no sudo access.
- Use the configured Docker daemon only for sandbox lifecycle management.
- Keep agent sandboxes read-only, capability-dropped, and network-disabled unless a specific use case requires an exception.
- Build a custom sandbox image for agent dependencies; do not install them at agent runtime.
- Keep gateway secrets, OAuth credentials, the Docker socket, and private host folders out of sandbox mounts.

## Routine checks

Run as the dedicated OpenClaw user:

```bash
export PATH="$HOME/.local/openclaw/bin:$HOME/.local/bin:$PATH"
export OPENCLAW_CONFIG_PATH="$HOME/.openclaw/openclaw.json"
export OPENCLAW_STATE_DIR="$HOME/.openclaw"
# This NAS uses the system Docker daemon; leave DOCKER_HOST unset.
# The openclaw service account must have explicit access to /var/run/docker.sock.

openclaw gateway status
openclaw sandbox list
openclaw models status --check
openclaw channels status --probe
openclaw security audit --deep
```

Restart the managed Gateway only when needed:

```bash
openclaw gateway restart
```

Sandbox containers are managed by OpenClaw. Do not start them manually with Docker.

## Updating OpenClaw

Preview first:

```bash
openclaw update status
openclaw update --dry-run
```

Then update interactively so plugin capability changes can be reviewed:

```bash
openclaw update
openclaw doctor --lint
openclaw security audit --deep
openclaw gateway status
```

Do not use automatic capability acceptance unless every requested permission expansion has been reviewed. Run `openclaw update cleanup` only after the updated installation has been stable long enough that rollback recovery files are no longer needed.

## Custom sandbox image

The default image is intentionally minimal. Create a versioned image whenever agents need additional operating-system tools.

The build script owns the recommended package baseline. Optional operator-specific package lists are deliberately untracked:

```text
scripts/build-sandbox-image.sh   # tracked baseline apt and pip packages
sandbox/apt-packages.txt         # ignored, NAS-specific Debian additions
sandbox/pip-packages.txt         # ignored, NAS-specific Python additions
sandbox/Dockerfile               # reads generated package lists during build
```

Create either optional local file when needed. It is listed in `.gitignore` and merged into the build automatically. Never place credentials in either file.

Run the versioned build-and-activate workflow as the dedicated OpenClaw user:

```bash
./scripts/build-sandbox-image.sh
```

It builds a dated image tag, updates the sandbox image setting, validates the configuration, restarts the Gateway, and recreates managed sandboxes. Use an explicit suffix for a second image on the same day:

```bash
./scripts/build-sandbox-image.sh 2026-09-09-r2
```

The script refuses to overwrite an existing tag, preserving rollback images.

### Playwright Chromium

Do not run `playwright install-deps` or `playwright install chromium` inside a running sandbox: its root filesystem is read-only. Add `playwright` to the local `sandbox/pip-packages.txt`, then bake Chromium and its system dependencies into the image:

```bash
./scripts/build-sandbox-image.sh 2026-09-09-playwright --playwright-chromium
```

The image will become materially larger. Runtime agents should not need to install Playwright browsers afterwards.

Legacy manual `Dockerfile` example:

```dockerfile
FROM openclaw-sandbox:bookworm-slim

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl jq ripgrep python3 file procps \
      rclone ffmpeg opencc gh \
 && rm -rf /var/lib/apt/lists/*

USER sandbox
```

Build it as the dedicated OpenClaw user:

```bash
docker build -t openclaw-sandbox:tools-YYYY-MM-DD .
```

Point `agents.defaults.sandbox.docker.image` to the new tag, then validate and recreate managed containers:

```bash
openclaw config validate
openclaw gateway restart
openclaw sandbox recreate --all
openclaw sandbox list
```

Never overwrite a previous image tag. Retaining the last working tag makes rollback straightforward.

Installing a command in the image does not grant it network access. For example, `curl`, `gh`, `git`, and `rclone` still cannot connect externally while the sandbox network remains disabled. Review and apply any network exception per agent; do not enable it globally by default.

`gh` inside the sandbox does not automatically receive OpenClaw's GitHub OAuth credentials. Do not copy OAuth tokens or other secrets into the image.

## Configuration changes

Use OpenClaw's config commands where practical:

```bash
openclaw config get agents.defaults.sandbox.docker.image
openclaw config validate
```

After a configuration change, validate before restarting the Gateway. Treat changes to gateway authentication, trusted proxies, Control UI origins, channel credentials, provider credentials, and sandbox mounts as security-sensitive.

Never expose or commit secret files, Gateway tokens, OAuth records, session state, or `.env` files.

## Backups

Protect and back up:

```text
~/.openclaw/
~/.config/openclaw/gateway.env
Sandbox Dockerfiles and image version records
```

Backups must be access-controlled or encrypted. If backing up SQLite state at the file level, capture the database together with its `-wal` and `-shm` files in one consistent filesystem snapshot.

## What not to do

- Do not grant the `openclaw` user sudo privileges.
- Do not mount a host Docker socket into a sandbox.
- Do not place tokens in Dockerfiles, images, workspaces, or repository files.
- Do not run broad Docker cleanup commands against a shared system Docker daemon.
- Do not delete OpenClaw state, workspaces, sessions, or recovery backups before confirming they are no longer needed.


## Current NAS sandbox and data mounts (2026-10-04)

This section records the current NAS configuration. Where it conflicts with the stricter baseline above, this section takes precedence; a future hardening pass should restore the intended read-only root filesystem, minimum capabilities, and restricted networking.

The Gateway currently uses the system Docker daemon, not rootless Docker. The OpenClaw service account needs explicit Docker-socket access. Docker-group access is effectively host-root-equivalent, so grant it only to the trusted service account and never mount the Docker socket into a sandbox.

The current sandbox uses `user: "0:0"`, a writable root filesystem, and `network: "bridge"`. These are higher-risk exceptions. Do not mount tokens, `.openclaw`, `/home/openclaw`, or other private host directories into a sandbox. Converge toward a non-root user, read-only root filesystem, minimum capabilities, and narrowly enabled networking.

### setupCommand

`setupCommand` runs once whenever a new sandbox container is created; it does not run on every agent turn. It must be idempotent, must not print or write credentials, and should not download unpinned content. Installing OS packages through it requires a writable root filesystem, a root user, and network access. Baking stable dependencies into a versioned image remains the safer long-term approach.

After changing `setupCommand`, the image, `docker.user`, `readOnlyRoot`, network, or a bind mount, run:

```bash
openclaw config validate
openclaw sandbox recreate --agent main --force
openclaw sandbox recreate --agent stock --force
openclaw sandbox recreate --agent health --force
```

Recreation interrupts that agent's current sandbox container. The next use creates it with the updated configuration.

### Per-agent data isolation

Every agent uses `/data` inside its sandbox, but each path maps to a separate host source:

| Agent | Host source | Sandbox path |
|---|---|---|
| main | `/home/openclaw/data/main` | `/data` |
| stock | `/home/openclaw/data/stock` | `/data` |
| health | `/home/openclaw/data/health` | `/data` |

Configure each agent independently under `agents.entries.<agent>.sandbox.docker`:

```json
{
  "binds": ["/home/openclaw/data/<agent>:/data:rw"],
  "dangerouslyAllowExternalBindSources": true
}
```

Do not configure `/home/openclaw/data:/data:rw` in `agents.defaults`, because that allows every agent to read and write every other agent's data. Sandbox programs must use `/data/...`, not host-absolute `/home/openclaw/...` paths. Do not substitute workspace symlinks for explicit bind mounts.

The host data directories are owned by `openclaw`. Grant human read access by minimum-privilege ACL only; currently `johnny` may read only `/home/openclaw/data/stock`. Do not grant health or main data to unnecessary accounts. Keep default ACLs on newly created stock subdirectories and periodically verify they were not overwritten.
