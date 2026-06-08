---
name: Linux Test Sandbox
description: This skill should be used when the user asks to "test in Linux",
  "run in a clean Linux environment", "try it in a container", "validate on Linux",
  "spawn a Linux box", "test on CentOS", or needs a script tested against a
  Linux distribution. Provides an ephemeral CentOS Stream 10 container via Docker.
---

# Linux Test Sandbox

## Purpose

Spin up a clean, ephemeral CentOS Stream 10 container for testing scripts,
validating cross-platform behavior, or running Linux-only toolchains.
The container is destroyed on exit; no state leaks across runs.

## Prerequisites

- Docker Desktop must be running (`docker info` succeeds).
- Internet access for the initial image pull and build.
- The `linux-sandbox:latest` snapshot image must be built once (see below).
- If the snapshot image is absent, fall back to `quay.io/centos/centos:stream10`
  and install dependencies inline (slower).

## Fresh Install (After Clone)

The `Dockerfile.sandbox` is bundled in `scripts/`. On a clean checkout,
run these steps once:

### 1. Pull the CentOS Stream 10 base image

```bash
docker pull quay.io/centos/centos:stream10
```

### 2. Build the snapshot image

From the repository root (where `linux-test-sandbox/` lives):

```bash
docker build -t linux-sandbox:latest -f linux-test-sandbox/scripts/Dockerfile.sandbox .
```

The trailing `.` is the build context — any directory works since the
Dockerfile has no `COPY` or `ADD` instructions.

### 3. Verify

```bash
docker run --rm linux-sandbox:latest bash -c "python3 --version && gcc --version | head -1"
```

Expected output:

```
Python 3.12.x
gcc (GCC) 14.x.y ...
```

### Rebuilding Later

To pick up newer CentOS packages or add tools:

```bash
docker pull quay.io/centos/centos:stream10
docker build --no-cache -t linux-sandbox:latest -f linux-test-sandbox/scripts/Dockerfile.sandbox .
```

## Enabling the Skill

The skill directory must be reachable by the assistant's skill discovery
mechanism. Two environments are covered below.

### Claude Code

Claude Code discovers skills in `.claude/skills/<name>/SKILL.md` at the
project root or user home. To enable:

**Option A — symlink (recommended):**

```bash
# From the repository root
ln -s "$(pwd)/linux-test-sandbox" .claude/skills/linux-test-sandbox
```

**Option B — copy:**

```bash
cp -r linux-test-sandbox .claude/skills/linux-test-sandbox
```

**Option C — custom skills directory** (in `claude.json` or project config):

```json
{
  "skills": {
    "customDirectories": ["path/to/linux-test-sandbox/.."]
  }
}
```

### Oh My Pi

Oh My Pi discovers skills through provider-based scanning (native `.omp`
projects, plugin bundles) and fallback custom directories. The layout
must be `<skills-root>/<name>/SKILL.md` (one level, non-recursive).

**Option A — place under the Oh My Pi skills root:**

```bash
# If the Oh My Pi project has a skills/ directory at its root:
ln -s "$(pwd)/linux-test-sandbox" /path/to/omp-project/skills/linux-test-sandbox
```

**Option B — custom directories** (in Oh My Pi config):

```json
{
  "skills": {
    "customDirectories": ["path/to/parent-of-linux-test-sandbox"]
  }
}
```

The parent directory is scanned non-recursively for `*/SKILL.md`, so point
`customDirectories` at the directory *containing* `linux-test-sandbox/`,
not at the skill directory itself.

After enabling, the skill appears in the assistant's system prompt under
discovered skills and is accessible via `skill://linux-test-sandbox`.

## When to Use

- Script testing that must not pollute the host.
- Cross-platform validation (the host is Windows).
- One-off Linux commands (curl, sed, awk, python, gcc, etc.).
- Multi-file projects that need a build step.
- Any time reproducibility matters — the container starts from a known state.

## Pre-Installed Toolchain

The `linux-sandbox:latest` image carries these packages; no install step needed
for common workflows:

| Tool       | Version (approx) | Category      |
|------------|------------------|---------------|
| bash       | 5.x              | Shell         |
| python3    | 3.12             | Runtime       |
| pip        | bundled          | Python pkgs   |
| gcc / g++  | 14.x             | C/C++ compile |
| make       | 4.x              | Build         |
| git        | 2.x              | VCS           |
| curl       | 8.x              | Network       |
| wget       | 1.x              | Network       |
| jq         | 1.x              | JSON          |
| gnupg      | 2.x              | Crypto        |
| unzip      | 6.x              | Archive       |

## Workflow

### Quick One-Liner

```bash
docker run --rm linux-sandbox:latest <command>
```

### Script from a File

Write the script to disk with the `write` tool, then execute.
The current working directory is bind-mounted at `/workspace`:

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
  bash /workspace/script.sh
```

### With Extra Dependencies

Install packages on-the-fly with dnf, then run the command:

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
  bash -c "dnf install -y -q <packages> && <commands>"
```

If the package is a development library (headers), enable CRB and EPEL first:

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
  bash -c "dnf install -y -q dnf-plugins-core epel-release && dnf config-manager --set-enabled crb && dnf install -y -q <devel-package> && <commands>"
```

### With Environment Variables

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace \
  -e FOO=bar -e BAZ=qux \
  linux-sandbox:latest bash -c '<commands>'
```

### Multi-File Project with Build

Create the project directory tree on the host. The bind-mount is recursive,
so every file under `$PWD` is visible inside the container:

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace/myapp linux-sandbox:latest \
  bash -c "make && ./build/main"
```

Build artifacts written to the mounted directory persist on the host after
teardown.

### Interactive Troubleshooting

```bash
docker run --rm -it -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest bash
```

Use `pty: true` in the bash tool to get a proper terminal.

### Fallback (No Snapshot Image)

If `linux-sandbox:latest` is not built, use the bare CentOS image with inline
dependency install:

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace quay.io/centos/centos:stream10 \
  bash -c "dnf install -y -q <packages> && <commands>"
```

## Key Invariants

1. **Always `--rm`.** Never leave stale containers behind.
2. **Always bind-mount `$PWD` to `/workspace`** when scripts or files are involved.
3. **dnf, not apt.** CentOS Stream uses dnf5.
4. **Package names are CentOS-style** (e.g., `libpq-devel` not `libpq-dev`,
   `gcc-c++` not `g++`). Consult `references/package-index.md` for mappings.
5. **pip, not pip3.** The `python3-pip` package provides `pip` on CentOS Stream 10.

## Reference Files

- **`references/docker-invocation.md`** — Full flag reference for `docker run`:
  volume mounts, networking, user namespaces, resource limits, interactive mode,
  WSL path translation.
- **`references/package-index.md`** — DNF packages organized by task category
  (compilers, databases, network tools, crypto, etc.) with CentOS-specific names.
