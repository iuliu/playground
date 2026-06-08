# Docker Invocation Reference

Complete flag reference for `docker run` in the Linux Test Sandbox context.

## Core Invocation

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
  bash -c '<commands>'
```

| Flag | Purpose | Required? |
|------|---------|-----------|
| `--rm` | Destroy container on exit. No stale state. | Always |
| `-v "$(pwd):/workspace"` | Bind-mount current directory to `/workspace` | When scripts/files involved |
| `-w /workspace` | Set working directory inside container | When `-v` is used |
| `linux-sandbox:latest` | Pre-built snapshot with common toolchains | Preferred |
| `bash -c '...'` | Execute inline commands | Standard |

## Volume Mounts

### Standard mount (read-write)

```bash
-v "$(pwd):/workspace"
```

Mounts the current directory and all subdirectories (recursive) at `/workspace`.
Files written by the container persist on the host.

### Read-only mount

```bash
-v "$(pwd):/workspace:ro"
```

Prevents the container from modifying host files. Use when you only need to read.

### Mount a specific directory

```bash
-v "/path/to/project:/workspace/project"
```

Mount any host path. Useful when the script lives outside `$PWD`.

### WSL path translation

When Docker Desktop uses the WSL2 backend, Windows paths must be translated:

```bash
# C:\Users\Iuliu\project  →  /mnt/c/Users/Iuliu/project
docker run --rm -v "/mnt/c/Users/Iuliu/project:/workspace" ...
```

The `$(pwd)` substitution automatically handles this when invoked from a WSL
shell. When invoking from PowerShell, use `${PWD}` or an absolute path.

### Windows path escaping

Paths with spaces must be quoted:

```bash
docker run --rm -v "C:/My Documents/project:/workspace" ...
```

## Networking

### Default (bridge)

The container gets an isolated network stack with outbound internet access.
Sufficient for `curl`, `dnf install`, `git clone`, and `pip install`.

### Host network

```bash
--network host
```

Container shares the host's network stack. Use when:
- The test needs to reach a service on the host's `localhost`.
- Bridge networking is misbehaving (rare).

### No network

```bash
--network none
```

Complete network isolation. Use to validate that the snapshot image is
self-sufficient — no package downloads, no external API calls.

### Custom DNS

```bash
--dns 8.8.8.8
```

Override DNS servers. Useful if the default Docker DNS is not resolving.

## Environment Variables

### Single variable

```bash
-e FOO=bar
```

### Multiple variables

```bash
-e FOO=bar -e BAZ=qux -e DEBUG=1
```

### From a file

```bash
--env-file ./test.env
```

File format: `KEY=value`, one per line. No quotes needed around values.

### Secrets warning

Environment variables are visible in `docker inspect` and process listings.
Do not pass secrets (API keys, tokens) via `-e`. Use a mounted file instead:

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
  bash -c 'export API_KEY=$(cat /workspace/.secret) && ./script.sh'
```

## User and Permissions

### Default (root)

The container process runs as root. Files written to the bind-mount are owned
by root on Linux hosts or mapped to the Docker Desktop user on Windows/macOS.

On Docker Desktop for Windows, this is typically not a problem — file ownership
is translated automatically.

### Run as host user

```bash
-u "$(id -u):$(id -g)"
```

Maps the container user to the host user. Needed on native Linux when root-owned
files cause permission issues on the host. On Windows with Docker Desktop, this
is rarely necessary.

## Resource Limits

### Memory

```bash
--memory 512m
```

Limit container memory. Useful for testing OOM behavior or constraining heavy
workloads.

### CPU

```bash
--cpus 2
```

Limit to 2 CPU cores.

### Combined

```bash
--memory 1g --cpus 4
```

## Interactive Mode

### PTY session

```bash
docker run --rm -it -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest bash
```

The `-it` flags allocate a pseudo-TTY and keep stdin open. The `bash` tool
must use `pty: true` for this to work properly.

### Piped stdin (non-interactive)

```bash
echo "input data" | docker run --rm -i linux-sandbox:latest bash -c 'cat > /tmp/in && process /tmp/in'
```

`-i` alone (no `-t`) keeps stdin open without allocating a TTY. Use for piping
data into the container.

## Entrypoint Override

```bash
--entrypoint /bin/bash
```

Override the image's default entrypoint. The `linux-sandbox:latest` image has
no custom entrypoint, so this is rarely needed. Use for debugging the image
itself.

## Container Naming

```bash
--name my-test
```

Name the container (incompatible with `--rm` when you need to inspect it after
the command completes). Combine with `docker rm my-test` afterward for cleanup.

Generally avoid — `--rm` is preferred for ephemeral test runs.

## Image Management

### Check if image exists

```bash
docker images linux-sandbox:latest --format '{{.Repository}}:{{.Tag}}'
```

### Pull latest CentOS base

```bash
docker pull quay.io/centos/centos:stream10
```

### Rebuild snapshot after Dockerfile changes

```bash
docker build --no-cache -t linux-sandbox:latest \
  -f ~/.linux-sandbox/Dockerfile.sandbox ~/.linux-sandbox/
```

### Clean up old images

```bash
docker image prune -f
```
