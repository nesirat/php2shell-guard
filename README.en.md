# php2shell-guard

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PHP2Shell](https://img.shields.io/badge/CVE-2026--109618%20%7C%20CVE-2026--109619-critical-red.svg)](https://www.php.net/archive/2026.php#2026-10-21-5)

A single tool for the **PHP2Shell** vulnerability pair (CVE-2026-109618 /
CVE-2026-109619): inventory, emergency mitigation, update orchestration and
compromise checks for **entire host fleets** — in one pass, over SSH.

> **Key point:** Updating to a patched PHP release is the **only** complete fix.
> Everything this tool does is a **stopgap** for the hours until the update —
> and the means to guarantee that the stopgap actually reaches every host.

---

## The problem in 60 seconds

On 2026-10-21 the PHP project published two critical RCE issues:

| CVE | CVSS | Mechanism | Affected |
|---|---|---|---|
| CVE-2026-109618 | 9.2 | OOM during request startup → `longjmp()` on partially initialised memory → RCE | PHP 5.4 – 8.5.11 |
| CVE-2026-109619 | 9.8 | Request state outlives the worker (stale state) → next request consumes freed memory → RCE | PHP 5.4 – 8.5.11 |

Fixed releases: **8.5.12**, **8.4.27**, **8.3.36**, **8.2.35**.
Branches 8.1 and older are EOL — there is **no** upstream fix
(only minimal source backports in the PHP team repos `PHP-<branch>-CVE-2026-109618-109619`).

**Highest risk: `mod_php`** (Apache module). There, request shutdown runs even
when startup fails — the attack is **application-independent**, before a single
line of application code executes. PHP-FPM is affected too (state is published
later), but not to the same application-independent degree.

Details: [`docs/MITIGATION.md`](docs/MITIGATION.md) · [`docs/ADVISORY-2026-10-21.md`](docs/ADVISORY-2026-10-21.md)
Complete operator guide: **[`docs/MANUAL.en.md`](docs/MANUAL.en.md)**

---

## Quick start

### 1. Inventory (read-only, no privileges)

```bash
./bin/php2shell-guard scan
./bin/php2shell-guard scan --json > scan.json
```

Exit codes: `0` = all patched, `2` = at least one critical installation
(handy as a **CI gate**).

### 2. Ship the emergency mitigation

```bash
./bin/php2shell-guard mitigate --dry-run     # preview first
sudo ./bin/php2shell-guard mitigate           # then apply
```

Writes a **managed** configuration per SAPI:

| SAPI | File | Effect |
|---|---|---|
| Apache `mod_php` | `/etc/apache2/conf-available/php2shell-guard.conf` (Debian) / `/etc/httpd/conf.d/php2shell-guard.conf` (RHEL) | `php_admin_value` for `memory_limit`, `session.upload_progress.enabled`, `fatal_error_backtraces` (8.5), input limits + `LimitRequestBody` |
| PHP-FPM | per pool file (`/etc/php/<ver>/fpm/pool.d/*.conf`) | `php_admin_value[...]` per pool (FPM has no global pool config) |
| php-cgi | `/etc/php/<ver>/cgi/conf.d/99-php2shell-guard.ini` | INI values (weaker, `PHP_INI_ALL`) |
| nginx | `/etc/nginx/conf.d/php2shell-guard.conf` | `client_max_body_size`, timeouts |

All workers are then **restarted** — mandatory, because stale state lives in
the worker process and a config reload does not clear it.

### 3. Update

```bash
./bin/php2shell-guard patch            # check what is available
sudo ./bin/php2shell-guard patch --apply
```

### 4. Verify

```bash
./bin/php2shell-guard verify --url https://example.org/ --vhost example.org
./bin/php2shell-guard ioc --since-days 30
```

`verify` drops a temporary probe into the web root, fetches **that file** over
HTTP, reads the **effective** configuration from the response (not the file on
disk — that is the difference that matters) and removes the probe again.
Use `--probe-path <url-path>` when the doc root is not the URL root.

---

## The batch: a whole fleet in one pass

```bash
make bundle                                   # build the single-file bundle
./bin/php2shell-fleet --hosts hosts.txt --cmd scan --parallel 10
./bin/php2shell-fleet --hosts hosts.txt --cmd mitigate --sudo --parallel 10
./bin/php2shell-fleet --hosts hosts.txt --cmd scan --report fleet-report.md
```

`hosts.txt` — one host per line, `#` comments allowed:

```
# web01.example.org
root@10.0.0.11
deploy@10.0.0.12
```

The bundle (`dist/php2shell-guard.sh`) is a **single file** with no
dependencies, copied to the target host over SSH via stdin — nothing needs to
be installed on the target.

Details: [`docs/FLEET.md`](docs/FLEET.md)

---

## A general solution, not a one-off hack

| Layer | Action | Tool |
|---|---|---|
| **1. Inventory** | know where PHP runs at all (including EOL branches and CLI) | `scan` |
| **2. Stopgap** | set measures admin-enforced + restart workers | `mitigate` |
| **3. Actual fix** | update to a patched release, migrate off EOL branches | `patch` |
| **4. Evidence** | check for compromise, verify measures, document state | `ioc`, `verify`, `report` |

As a permanent **CI gate**:

```yaml
- name: PHP2Shell-Gate
  run: |
    curl -fsSL https://github.com/nesirat/php2shell-guard/releases/download/v0.1.0/php2shell-guard.sh \
      | sudo bash -s -- scan --json
```

Exit code `2` fails the build — unpatched PHP versions cannot slip into
production unnoticed.

---

## What the mitigation does — and what it does not

**Does (temporarily):**

* `memory_limit = -1` **admin-enforced** (via `php_admin_value`) — removes the
  controllable OOM from the picture.
* `session.upload_progress.enabled = 0` **admin-enforced** — closes the
  confirmed producer/consumer path for stale state.
* `fatal_error_backtraces = 0` (PHP 8.5 only) — removes the confirmed producer.
* `post_max_size` / `upload_max_filesize` / `max_input_nesting_level` /
  `max_input_vars` / `max_file_uploads` — shrink the attack surface.
* `LimitRequestBody` / `LimitRequestFields` / `LimitRequestFieldSize` (Apache)
  or `client_max_body_size` (nginx) — act **before** the PHP parser.
* `--cgroup-limit` sets an **availability boundary** (`MemoryMax`) so that
  `memory_limit = -1` does not turn into a DoS hole.

**Does not:**

* It does **not** fix the vulnerability. An allocation failure below
  `memory_limit = -1` can still reach the affected path.
* Multipart part count and per-part header count cannot be limited natively in
  **nginx** — that requires a WAF (ModSecurity/NAXSI).
* `RLIMIT_AS` / `RLIMIT_DATA` must **not** be set: they produce exactly the
  allocation failures that re-trigger the path. The tool deliberately uses
  `MemoryMax` (cgroup) instead.
* `ini_set()` and `.user.ini` are **not** substitutes — they apply too late.

---

## Commands

| Command | Purpose | Privileges |
|---|---|---|
| `scan` | PHP versions, SAPIs, mitigation status | none |
| `mitigate` | emergency mitigation + worker restart | root |
| `patch` | package update (with `--apply`) | root for `--apply` |
| `verify` | check effective configuration over HTTP | none (writes a probe into the web root) |
| `ioc` | compromise indicators | read access to web root/logs |
| `report` | JSON results → Markdown/CSV | none |
| `templates` | show the configuration that would be applied | none |

Global options: `--json`, `--dry-run`, `--yes`, `--version`, `--help`.

Full command reference, troubleshooting, FAQ and operations guide:
**[`docs/MANUAL.en.md`](docs/MANUAL.en.md)** (DE: [`docs/MANUAL.md`](docs/MANUAL.md)).

---

## Requirements

* `bash` ≥ 3.2, `grep`/`sed`/`awk`/`find` (POSIX) — no Python/jq required
* `curl` for `verify` only
* `ssh` for `php2shell-fleet` only
* tested on Debian/Ubuntu, RHEL/Rocky/Alma, Alpine, macOS (BSD tools!)

---

## Contributing

Contributions welcome — especially: **more operating systems**, **more SAPIs**,
**additional IOC patterns**, **Ansible/Salt integrations**.
See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`SECURITY.md`](SECURITY.md).

This tool is deliberately kept **freely available**: the window between an
advisory and the patching of individual systems is exactly the window in which
attackers reliably take systems over. Tools that shorten that window belong in
everyone's hands — not in a niche.

## Sources

* PHP Security Advisory: <https://www.php.net/archive/2026.php#2026-10-21-5>
* GHSA-w8hw-w9fx-j79w (CVE-2026-109618): <https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w>
* GHSA-6wmf-4rv5-p3rp (CVE-2026-109619): <https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp>
* NCSC (UK): <https://www.ncsc.gov.uk/news/critical-security-issue-affecting-php>
* EOL backports: <https://github.com/php/php-src/tree/PHP-8.1-CVE-2026-109618-109619>

## License

MIT — see [`LICENSE`](LICENSE). German version: [`README.md`](README.md).
