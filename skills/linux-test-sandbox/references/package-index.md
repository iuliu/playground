# DNF Package Index

CentOS Stream 10 packages organized by task category. Use this to find the
correct package name for a given need — CentOS naming differs from Debian/Ubuntu.

## How to Install

```bash
dnf install -y -q <package1> <package2> ...
```

Packages already in the `linux-sandbox:latest` snapshot are marked with **[pre]**.

## C / C++ Toolchain

| Task | Package(s) | Notes |
|------|-----------|-------|
| Compile C | `gcc` **[pre]** | |
| Compile C++ | `gcc-c++` **[pre]** | NOT `g++` |
| Build automation | `make` **[pre]**, `cmake`, `autoconf`, `automake` | |
| Debug symbols | `gdb`, `valgrind` | |
| Static analysis | `cppcheck`, `clang-tools-extra` | |
| C standard library headers | `glibc-devel` | Usually pulled by `gcc` |

## Python

| Task | Package(s) | Notes |
|------|-----------|-------|
| Runtime | `python3` **[pre]** | Python 3.12.x |
| Package installer | `python3-pip` **[pre]** | Provides `pip`, not `pip3` |
| C extension headers | `python3-devel` | Needed for packages with C extensions (numpy, psycopg2, etc.) |
| Virtual environments | `python3` | `venv` is included in the base `python3` package |

## Node.js

| Task | Package(s) | Notes |
|------|-----------|-------|
| Runtime + npm | `nodejs`, `npm` | |

## Network Tools

| Task | Package(s) | Notes |
|------|-----------|-------|
| HTTP client | `curl` **[pre]**, `wget` **[pre]** | |
| DNS lookup | `bind-utils` | Provides `dig`, `nslookup` |
| Network debugging | `netcat`, `tcpdump`, `nmap` | |
| SSL/TLS certs | `ca-certificates` **[pre]** | |
| SSH client | `openssh-clients` | Provides `ssh`, `scp`, `sftp` |

## Text Processing

| Task | Package(s) | Notes |
|------|-----------|-------|
| JSON | `jq` **[pre]** | |
| XML | `xmlstarlet` | |
| CSV toolkit | `csvkit` | Python-based; install via `pip` |
| Stream editor | `sed` | Usually pre-installed |
| Pattern matching | `gawk` | GNU awk |

## Databases

### Client Libraries

| Database | Package | Notes |
|----------|---------|-------|
| SQLite | `sqlite` | CLI + library |
| PostgreSQL | `postgresql` | `psql` client |
| MySQL / MariaDB | `mysql` | CLI client |

### Development Headers

These require enabling CRB (CodeReady Builder) and EPEL repos first:

```bash
dnf install -y -q dnf-plugins-core epel-release
dnf config-manager --set-enabled crb
dnf install -y -q <devel-package>
```

| Database | Package | Ubuntu equiv |
|----------|---------|-------------|
| SQLite | `sqlite-devel` | `libsqlite3-dev` |
| PostgreSQL | `libpq-devel` | `libpq-dev` |
| MySQL / MariaDB | `mariadb-connector-c-devel` | `libmysqlclient-dev` |

## Compression & Archives

| Task | Package(s) | Notes |
|------|-----------|-------|
| Zip | `unzip` **[pre]**, `zip` | |
| Tar + gzip/bzip2/xz | `tar`, `gzip`, `bzip2`, `xz` | Usually pre-installed |

## Crypto & SSL

| Task | Package(s) | Notes |
|------|-----------|-------|
| OpenSSL | `openssl`, `openssl-devel` | |
| GPG | `gnupg` **[pre]** | |

## Version Control

| Task | Package(s) | Notes |
|------|-----------|-------|
| Git | `git` **[pre]** | |

## Shell & Utilities

| Task | Package(s) | Notes |
|------|-----------|-------|
| Shell | `bash` **[pre]** | |
| Process listing | `procps-ng` | Provides `ps`, `top`, `watch` |
| File utils | `findutils`, `diffutils` | Usually pre-installed |
| Sudo | `sudo` | Only if needed for testing privilege escalation |

## Enabling Extra Repositories

Some packages live outside the default CentOS Stream repos:

### CRB (CodeReady Builder)

Development packages and headers:

```bash
dnf install -y -q dnf-plugins-core
dnf config-manager --set-enabled crb
```

### EPEL (Extra Packages for Enterprise Linux)

Community-maintained add-on packages:

```bash
dnf install -y -q epel-release
```

### EPEL Next

Pre-release packages targeting the next RHEL point release:

```bash
dnf install -y -q epel-next-release
```
