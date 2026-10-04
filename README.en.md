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
- Manage general agent dependencies with `setupCommand` when a sandbox is created; do not maintain a custom sandbox image for routine dependencies.
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

## Sandbox dependencies: setupCommand

General agent sandboxes use the default image:

```text
openclaw-sandbox:bookworm-slim
```

Routine apt, pip, and command dependencies belong in `agents.defaults.sandbox.docker.setupCommand`; do not build or maintain a custom sandbox image. This keeps dependency declarations in `~/.openclaw/openclaw.json` and avoids Dockerfile and image-tag drift after OpenClaw updates.

The current NAS baseline is:

```json
{
  "image": "openclaw-sandbox:bookworm-slim",
  "readOnlyRoot": false,
  "user": "0:0",
  "network": "bridge",
  "tmpfs": ["/tmp", "/var/tmp", "/run"],
  "capDrop": ["AUDIT_WRITE", "KILL", "MKNOD", "NET_BIND_SERVICE", "NET_RAW", "SETPCAP", "SYS_CHROOT"],
  "setupCommand": "export DEBIAN_FRONTEND=noninteractive; apt-get -o APT::Sandbox::User=root update && apt-get -o APT::Sandbox::User=root install -y git curl jq ripgrep python3 file procps rclone ffmpeg opencc gh python3-venv python3-pip && python3 -m pip install --break-system-packages FinMind tqdm finmind-mcp python-dotenv yt_dlp"
}
```

`APT::Sandbox::User=root` is required because APT normally drops to `_apt`, which can fail with `setgroups`, `setuid`, or cache-directory permission errors in this restricted Docker sandbox.

After changing `setupCommand`:

```bash
openclaw config validate
openclaw sandbox recreate --all --force
```

It runs once per newly created container. Keep it idempotent and never include tokens, credentials, PATs, or untrusted download scripts. Use the OpenClaw sandbox browser for browser automation instead of installing Chromium into the general sandbox.

### Legacy custom-image procedure (do not use)

The remaining custom-image notes are retained only to identify or retire existing images. Do not follow them for new general sandbox dependencies; use `setupCommand` above.

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


### Image policy and sandbox browser image

The regular agent sandbox currently uses the default `openclaw-sandbox:bookworm-slim` image; normal operations do not use a custom sandbox image. Extra commands and runtime dependencies are managed through `setupCommand`. The existing `scripts/build-sandbox-image.sh` is retained only for exceptional fixed dependencies that cannot be provided by `setupCommand`, and is not part of routine maintenance.

The sandbox browser is a separate image. It currently uses `openclaw-sandbox-browser:bookworm-slim`; do not substitute the regular sandbox image or a Gateway browser image. On a new NAS, after image cleanup, or when the browser image is missing, use a source checkout that matches the installed OpenClaw version:

```bash
scripts/sandbox-browser-setup.sh
docker image inspect openclaw-sandbox-browser:bookworm-slim
openclaw sandbox recreate --browser --all --force
```

This browser-image helper is not included in the global npm package, so a source checkout is required. Run `openclaw config validate` first and confirm `sandbox.browser.enabled: true`, the configured image name, and the browser network. The browser sandbox has its own Docker network; do not share private data through ordinary agent `docker.binds`.


A default image does not mean that the image exists automatically. On a new NAS, after Docker-image cleanup, or after an image-missing error, build the regular sandbox image from a source checkout matching the installed OpenClaw version:

```bash
scripts/sandbox-setup.sh
docker image inspect openclaw-sandbox:bookworm-slim
```

Then build the browser image from the same version and enable it with the browser-recreation step in this section. Both images use the official default tags; routine operations do not need custom tags.
