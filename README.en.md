# OpenClaw NAS Maintenance Guide (English)

This guide documents a security-focused OpenClaw deployment:

```text
Reverse proxy
  -> host-native OpenClaw Gateway (dedicated non-root user)
  -> rootless Docker sandbox containers
  -> agent tools and shell commands
```

The Gateway runs natively on the host. All agent command execution stays in a sandbox image. Credentials remain in the Gateway's protected state and are not baked into images or mounted into sandboxes.

## Operating model

- Run the Gateway as a dedicated `openclaw` user with no sudo access.
- Run rootless Docker under that same user only for sandbox lifecycle management.
- Keep agent sandboxes read-only, capability-dropped, and network-disabled unless a specific use case requires an exception.
- Build a custom sandbox image for agent dependencies; do not install them at agent runtime.
- Keep gateway secrets, OAuth credentials, the Docker socket, and private host folders out of sandbox mounts.

## Routine checks

Run as the dedicated OpenClaw user:

```bash
export PATH="$HOME/.local/openclaw/bin:$HOME/.local/bin:$PATH"
export OPENCLAW_CONFIG_PATH="$HOME/.openclaw/openclaw.json"
export OPENCLAW_STATE_DIR="$HOME/.openclaw"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

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

Example `Dockerfile`:

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
