# Linux Test Sandbox — Implementation Plan

## Status: Plan
## Target: Windows 11 + Docker Desktop 29.5.2

---

## 1. Overview

Provide a repeatable, zero-friction mechanism to execute scripts inside a clean,
ephemeral Linux container on this machine. The primary consumer is the AI assistant
(Claude), which needs to:

1. Receive a script or command from the user.
2. Spin up a Linux container.
3. Install any declared dependencies.
4. Execute the script.
5. Report results.
6. Tear down the container — no state leaks across runs.

---

## 2. Architecture Decisions

### 2.1 Base Image: `quay.io/centos/centos:stream10`

CentOS Stream 10 is the current rolling-release distribution tracking just ahead
of RHEL 10. It provides:

- **dnf5** package manager — modern, fast dependency resolution.
- **glibc** — no musl compatibility surprises; all precompiled binaries work.
- **EPEL / CRB** repos available for extended package coverage.
- **Familiarity** — the user already runs CentOS 8 and CentOS 10 WSL distros.

| Candidate  | Pros                                      | Cons                              | Verdict    |
|------------|-------------------------------------------|-----------------------------------|------------|
| CentOS Stream 10 | RHEL-compatible, dnf5, user familiarity | Rolling (not point-release LTS)  | **Chosen** |
| Ubuntu     | Largest package set, LTS support          | Different ecosystem than target   | Reject     |
| Alpine     | ~3 MB, fast pull                          | musl libc, no dnf/apt             | Reject     |

### 2.2 Container Lifecycle: Ephemeral (`--rm`)

Every test run uses `docker run --rm`. The container is destroyed on exit.
No persistent containers, no name collisions, no stale state.

### 2.3 File Mounting: Bind-mount `$PWD` → `/workspace`

The current working directory (where scripts and test data live) is mounted
read-write at `/workspace` inside the container. This means:

- Scripts written to disk by the assistant are immediately visible inside the container.
- Output files written by the container persist on the host after teardown.
- No `docker cp` or intermediate copies needed.

### 2.4 Dependency Declaration: Inline + Cached Layers
Short-term (Phase 1): Dependencies are passed as a list of dnf package names
in the `docker run` command.

Medium-term (skill): A pre-built snapshot image with common toolchains
(python3, gcc, make, curl, git, jq) is maintained locally. The ephemeral
container starts from this snapshot, then installs any additional test-specific
packages on top. This cuts `dnf install` time from
~20s to ~2s for most runs.

### 2.5 Invocation Surface

The primary interface is a single `docker run` one-liner the assistant can
emit from any tool (bash, eval, etc.). No wrapper script on the host is
strictly required, but a convenience PowerShell function is provided for
interactive human use.

---

## 3. Phases

### Phase 1: Bootstrap & Validation

**Goal:** Pull the base image and validate the end-to-end flow works.

**Tasks:**

1. **Pull `quay.io/centos/centos:stream10`**
   ```bash
   docker pull quay.io/centos/centos:stream10
   ```
   Expected: ~60 MB download, image listed in `docker images`.

2. **Smoke-test ephemeral execution**
   ```bash
   docker run --rm -v "$(pwd):/workspace" -w /workspace quay.io/centos/centos:stream10 \
     bash -c "echo 'Linux sandbox online' && uname -a && cat /etc/os-release"
   ```
   Expected: container starts, prints system info, exits cleanly. No residual
   container in `docker ps -a`.

3. **Smoke-test dependency install + script execution**
   ```bash
   docker run --rm -v "$(pwd):/workspace" -w /workspace quay.io/centos/centos:stream10 \
     bash -c "dnf install -y -q python3 && python3 -c 'print(2+2)'"
   ```
   Expected: `4`. Container gone after exit.

4. **Smoke-test file round-trip**
   ```bash
   echo "hello from host" > ./sandbox-test.txt
   docker run --rm -v "$(pwd):/workspace" -w /workspace quay.io/centos/centos:stream10 \
     bash -c "cat sandbox-test.txt && echo 'roundtrip OK' > sandbox-out.txt"
   cat ./sandbox-out.txt
   rm ./sandbox-test.txt ./sandbox-out.txt
   ```
   Expected: `hello from host` from container, `roundtrip OK` on host.

**Deliverable:** Docker base image cached locally. Three passing smoke tests
proving: execution, dependency install, and file I/O.

---

### Phase 2: Pre-Baked Snapshot Image

**Goal:** Build a `linux-sandbox:latest` image with common toolchains
pre-installed, so most test runs skip the `dnf install` step.

**Tasks:**

1. **Create `Dockerfile.sandbox`** in `~/.linux-sandbox/` (or a configurable location):
   ```dockerfile
   FROM quay.io/centos/centos:stream10
   RUN dnf install -y -q \
       bash \
       ca-certificates \
       curl \
       gcc \
       gcc-c++ \
       git \
       gnupg \
       jq \
       make \
       python3 \
       python3-pip \
       unzip \
       wget \
     && dnf clean all
   # Enable CRB (CodeReady Builder) and EPEL for dev libraries on demand:
   #   dnf install -y dnf-plugins-core
   #   dnf config-manager --set-enabled crb
   #   dnf install -y epel-release
   WORKDIR /workspace
   ```

2. **Build the image:**
   ```bash
   docker build -t linux-sandbox:latest -f ~/.linux-sandbox/Dockerfile.sandbox ~/.linux-sandbox/
   ```

3. **Smoke-test fast start:**
   ```bash
   time docker run --rm -v "$(pwd):/workspace" linux-sandbox:latest \
     bash -c "python3 --version && gcc --version | head -1 && git --version"
   ```

**Deliverable:** `linux-sandbox:latest` image. Base deps available without
network round-trips. Build is repeatable — edit `Dockerfile.sandbox` and
rebuild to add/remove toolchains.

---

### Phase 3: Skill File

**Goal:** Encode the sandbox workflow as a skill so the assistant never
rediscovers the invocation pattern, base image name, mount conventions,
or dependency installation syntax.

**Location:** `.claude/skills/linux-test-sandbox/`
(If the Oh My Pi harness uses a different skills directory, adjust accordingly.)

**Structure:**

```
.claude/skills/linux-test-sandbox/
├── SKILL.md                  # Core workflow: when to use, how to invoke
├── references/
│   ├── docker-invocation.md  # Full docker run flags, variants, escape hatches
│   └── package-index.md      # Common dnf packages mapped to use-cases
└── scripts/
    └── sandbox-run.sh        # Convenience wrapper (optional; can be run directly)
```

**SKILL.md contents (sketch):**

```markdown
---
name: Linux Test Sandbox
description: This skill should be used when the user asks to "test in Linux",
  "run in a clean Linux environment", "try it in a container", "validate on Linux",
  "spawn a Linux box", or needs a script tested against a Linux distribution.
---

# Linux Test Sandbox

## Purpose

Provide a clean, ephemeral CentOS Stream 10 container for testing scripts, applications,
validating cross-platform behavior, or running Linux-only toolchains.

## When to Use

- Script testing that must not pollute the host
- Cross-platform validation (the host is Windows)
- One-off Linux commands (curl, sed, awk, python, gcc, etc.)
- Any time reproducibility matters — the container starts from a known state

## Workflow

### Base Invocation

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
  bash -c '<commands>'
```

### With Extra Dependencies

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
  bash -c "dnf install -y -q <packages> && <commands>"
```

### With Environment Variables

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace \
  -e FOO=bar -e BAZ=qux \
  linux-sandbox:latest bash -c '<commands>'
```

### Running a Saved Script

Write the script to disk with the `write` tool, then execute:

```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
  bash /workspace/test_script.sh
```

## Reference Files

- **`references/docker-invocation.md`** — Full flag reference, networking, volumes, user namespace
- **`references/package-index.md`** — DNF packages by category (compilers, databases, network tools, etc.)
```

**Deliverable:** Skill directory with SKILL.md and reference files. Assistant
can invoke `docker run` with the correct flags without looking anything up.

---

### Phase 4: Validation & Iteration

**Goal:** Exercise the skill end-to-end with real scenarios.

**Tasks:**

1. **Python script test:**
   - Write a script that uses `requests` (not pre-installed).
   - Run in sandbox with `pip install requests` as a dependency step.
   - Verify output.

2. **C compilation test:**
   - Write a small C program.
   - Compile with `gcc` inside the sandbox.
   - Run the binary and capture output.

3. **Network test:**
   - `curl https://httpbin.org/json` inside the container.
   - Verify JSON response.

4. **Multi-file project test:**
   - Create a directory with multiple scripts.
   - Mount the parent directory.
   - Verify all files are visible and executable.

5. **Edge case — no network:**
   - `docker run --network none` to simulate offline.
   - Verify pre-installed packages still work.

**Deliverable:** Five documented test scenarios, all passing. Any gaps found
are patched back into the skill or Dockerfile.

---

## 4. Usage Patterns (Post-Implementation)

### Pattern A: Quick one-liner

User: *"What does `ls /proc` look like on Linux?"*

Assistant emits:
```bash
docker run --rm linux-sandbox:latest ls /proc
```

### Pattern B: Script from file

User: *"Write a bash script that parses a CSV and test it on Linux."*

Assistant:
1. Writes `parse_csv.sh` to disk.
2. Runs:
   ```bash
   docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
     bash parse_csv.sh
   ```

### Pattern C: Dependency-heavy test

User: *"Test this Python script that needs numpy and postgres client libraries."*

Assistant:
```bash
docker run --rm -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest \
  bash -c "dnf install -y -q libpq-devel && pip install numpy psycopg2 && python3 test_db.py"
```

### Pattern D: Interactive troubleshooting

User: *"Something's weird, I need you to poke around in Linux."*
Assistant:
```bash
docker run --rm -it -v "$(pwd):/workspace" -w /workspace linux-sandbox:latest bash
```
*(Note: `-it` requires a PTY; the `bash` tool with `pty: true` can handle this.)*

### Pattern E: Multi-file project with build

User: *"Write a C program in `myapp/` that uses a Makefile and test it on Linux."*

Assistant:
1. Creates the project directory and files on the host:
   ```
   myapp/
   ├── Makefile
   ├── src/
   │   ├── main.c
   │   └── util.c
   └── include/
       └── util.h
   ```
2. The entire `myapp/` tree is visible inside the container because
   the bind-mount is recursive — `-v "$(pwd):/workspace"` mounts the
   current directory and everything under it.
3. Runs:
   ```bash
   docker run --rm -v "$(pwd):/workspace" -w /workspace/myapp linux-sandbox:latest \
     bash -c "make && ./build/main"
   ```
4. Output files (e.g. `myapp/build/main`) persist on the host after teardown.

---

## 5. Risks & Mitigations

| Risk                                      | Mitigation                                                     |
|-------------------------------------------|----------------------------------------------------------------|
| `dnf install` slows every test             | Phase 2 snapshot image with common deps pre-installed          |
| Image grows stale (old packages)          | Skill includes `docker pull linux-sandbox:latest` refresh step |
| Dev packages missing (e.g. `libpq-devel`)  | Enable CRB/EPEL repos; documented in `references/package-index.md` |
| Container can't reach internet            | Snapshot image carries essential packages; `--network host` escape hatch |
| Windows paths with spaces break `-v`      | Use `"$(pwd)"` quoting; document in reference file             |
| Docker Desktop not running                | Skill instructs assistant to run `docker info` first; report clear error |
| WSL / Docker backend mismatch (filesystem) | Mount from WSL-compatible path (`/mnt/c/...`); document        |

---

## 6. Acceptance Criteria

1. [ ] `quay.io/centos/centos:stream10` pulled and cached.
2. [ ] Smoke tests pass: execution, deps, file round-trip.
3. [ ] `Dockerfile.sandbox` exists and `linux-sandbox:latest` is built.
4. [ ] Fast-start test completes in <5 seconds (no `dnf install` needed).
5. [ ] Skill directory created at `.claude/skills/linux-test-sandbox/` with:
   - [ ] `SKILL.md` with correct frontmatter (third-person, trigger phrases).
   - [ ] `references/docker-invocation.md` with full flag reference.
   - [ ] `references/package-index.md` with common package mappings.
6. [ ] Five scenario tests from Phase 4 all pass.

---

## 7. File Manifest (Post-Implementation)

```
.claude/skills/linux-test-sandbox/
├── SKILL.md                    # Skill entry point
├── references/
│   ├── docker-invocation.md    # Full docker run reference
│   └── package-index.md        # DNF package catalog
└── scripts/
    └── Dockerfile.sandbox      # Snapshot image definition (bundled)
```

The `~/.linux-sandbox/` directory is no longer required — the Dockerfile is
bundled in the skill and `docker build` can reference it directly from the
cloned repository.
