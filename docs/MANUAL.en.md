# Manual — php2shell-guard

> Complete operator guide. For a quick start see [`../README.en.md`](../README.en.md).

---

## 1. Installation

### 1.1 Single-file bundle (recommended for fleets)

No installation, no dependencies — one file copied to the target host via stdin.

```bash
git clone https://github.com/nesirat/php2shell-guard.git
cd php2shell-guard
make bundle
```

On the target host:

```bash
curl -fsSL https://github.com/nesirat/php2shell-guard/releases/download/v0.1.0/php2shell-guard.sh \
  | sudo bash -s -- scan --json
```

### 1.2 Install from source

```bash
sudo make install PREFIX=/usr/local
```

### 1.3 Requirements

| Tool | Where | Needed for |
|---|---|---|
| `bash` ≥ 3.2 | everywhere | all commands |
| `grep`, `sed`, `awk`, `find` | POSIX | all commands |
| `curl` | optional | `verify` |
| `ssh` | optional | `php2shell-fleet` |
| `python3` | optional | test suite only (JSON validation) |

Verified on Debian/Ubuntu, RHEL/Rocky/Alma, Alpine, SUSE and macOS (BSD tools).

---

## 2. Concepts in 30 seconds

```
scan      →  What runs here, is it patched, is the mitigation effective?
mitigate  →  Apply the stopgap (admin-enforced) + restart workers
patch     →  Update to a patched release
verify    →  Does the configuration actually take effect? (effective, over HTTP)
ioc       →  Has this host possibly been compromised?
report    →  Merge results from multiple hosts
```

**Order during an incident:** `scan` → `mitigate` → `patch` → `verify` → `ioc`.

**Exit codes (all commands):**

| Code | Meaning |
|---|---|
| `0` | success, no critical finding |
| `1` | error (configuration, privileges, network) |
| `2` | **critical finding** — unpatched PHP without an effective mitigation |
| `64` | unknown command |

`2` is deliberately not an *error* but a *finding* — that is what makes the tool
usable as a CI gate.

---

## 3. Command reference

### 3.1 `scan` — inventory

```bash
php2shell-guard scan [--json]
```

Detects installed PHP versions (CLI, FPM, CGI), the SAPI actually in use, the
effectiveness of the mitigation and the patch status.

| Field (JSON) | Meaning |
|---|---|
| `sapi` | `apache2handler`, `fpm`, `cgi-fcgi`, `cli` |
| `php_version` | installed version (incl. distro suffix) |
| `branch` | `8.1`, `8.3`, … |
| `fixed_min` | version containing the official fix — **empty = EOL branch without upstream fix** |
| `patched` | `true`/`false` |
| `mitigation` | `applied` / `partial` / `missing` |
| `risk` | `low` / `medium` / `critical` |
| `memory_limit_enforcement` | `admin` (effective) / `ini` (overridable) / `none` |

| `mitigation` | Meaning |
|---|---|
| `applied` | `memory_limit=-1` **and** `session.upload_progress.enabled=0` admin-enforced |
| `partial` | only partly set, or not admin-enforced (the app can override via `ini_set()`) |
| `missing` | nothing effective in place |

| `risk` | Meaning |
|---|---|
| `low` | version contains the official fix |
| `medium` | unpatched but mitigation fully effective — **the update is still mandatory** |
| `critical` | unpatched and no effective mitigation |

### 3.2 `mitigate` — emergency stopgap

```bash
sudo php2shell-guard mitigate [--dry-run] [--yes] [--fix-overrides]
                                [--post-max 8M] [--upload-max 8M]
                                [--cgroup-limit 1024] [--json]
```

| Option | Meaning |
|---|---|
| `--dry-run` | preview only |
| `--yes` | auto-confirm prompts |
| `--fix-overrides` | convert `php_value` overrides in vhosts to `php_admin_value` |
| `--post-max` | value for `post_max_size` (default `8M`) |
| `--upload-max` | value for `upload_max_filesize` (default `8M`) |
| `--cgroup-limit` | `MemoryMax` in MB for the FPM service (recommended) |

**Files written:**

| SAPI | Target file |
|---|---|
| Apache `mod_php` | `/etc/apache2/conf-available/php2shell-guard.conf` (+ `a2enconf`) or `/etc/httpd/conf.d/php2shell-guard.conf` |
| PHP-FPM | every pool in `/etc/php/<ver>/fpm/pool.d/*.conf` (`php_admin_value[]` per pool) |
| php-cgi | `/etc/php/<ver>/cgi/conf.d/99-php2shell-guard.ini` or `/etc/php.d/99-php2shell-guard.ini` |
| nginx | `/etc/nginx/conf.d/php2shell-guard.conf` |

**Sequence:** back up affected files (`*.p2s-backup.<timestamp>`) → write config
(marked `>>> php2shell-guard >>>` / `<<< php2shell-guard <<<`) → validate
(`apachectl -t`, `nginx -t`) → **restart all workers**.

Idempotent: a second run replaces the managed block instead of adding a second
one; existing pool settings are preserved.

**Important:** `memory_limit = -1` is intentional (the attack needs a
controllable OOM) — use `--cgroup-limit` to avoid a DoS hole. `RLIMIT_AS` /
`RLIMIT_DATA` are never set.

### 3.3 `patch` — update

```bash
php2shell-guard patch [--apply] [--dry-run] [--yes] [--json]
```

Lists installed PHP packages, available updates and warns about EOL branches
with a concrete migration recommendation. With `--apply` only PHP packages are
upgraded, then FPM/Apache are restarted.

### 3.4 `verify` — check the effective configuration

```bash
php2shell-guard verify [--url URL] [--vhost HOST] [--docroot PATH] [--probe-path PATH] [--json]
```

| Option | Meaning |
|---|---|
| `--url` | base URL of the web server (default `http://127.0.0.1/`) |
| `--vhost` | `Host:` header for the request |
| `--docroot` | web root (auto-detected by default) |
| `--probe-path` | URL path of the probe if the doc root is not the URL root |

Writes a temporary probe into the web root (`__p2s_probe_<pid>.php`), fetches
**that file** over HTTP, evaluates the effective `ini` values, then deletes the
probe.

Checked: `memory_limit`, `session.upload_progress.enabled`, `post_max_size`,
`upload_max_filesize`, `max_input_nesting_level`, `max_input_vars`,
`max_file_uploads`, `fatal_error_backtraces` (8.5+), plus the patch status of
the running version.

### 3.5 `ioc` — compromise indicators

```bash
php2shell-guard ioc [--since-days 14] [--max-files 500] [--json]
```

Exit code `1` when findings are reported. Details: [`DETECTION.md`](DETECTION.md).

### 3.6 `report` — consolidation

```bash
php2shell-guard report [--out FILE.md] [--csv FILE.csv] <scan.json> [scan.json …]
```

Produces a Markdown table across all hosts with a risk summary.

### 3.7 `templates` — show the configuration

```bash
php2shell-guard templates [apache|fpm|ini|nginx|all]
```

Useful for integrating the configuration into Ansible, Puppet or Git.

---

## 4. Fleet operation

```bash
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd scan --parallel 10
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd mitigate --sudo --parallel 5
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd scan --report fleet-report.md
```

| Option | Meaning |
|---|---|
| `--hosts <file>` | host list (mandatory), one `user@host` per line |
| `--cmd <command>` | `scan` (default), `mitigate`, `patch`, `verify`, `ioc` |
| `--parallel <n>` | concurrent connections (default 8) |
| `--sudo` | run the remote command with `sudo -n` (NOPASSWD required) |
| `--identity <key>` | SSH identity file |
| `--ssh-opts "<opts>"` | additional SSH options |
| `--extra "<args>"` | extra arguments for the remote command |
| `--out <dir>` | result directory |
| `--report <file>` | Markdown report |
| `--local` | run locally instead of over SSH (testing) |

---

## 5. CI integration

```yaml
- name: PHP2Shell-Gate
  run: |
    curl -fsSL https://github.com/nesirat/php2shell-guard/releases/download/v0.1.0/php2shell-guard.sh \
      | sudo bash -s -- scan --json
```

Exit code `2` fails the build. `scan` needs no root privileges.

Daily inventory:

```bash
0 6 * * * /usr/local/bin/php2shell-fleet --hosts /etc/p2s/hosts.txt --cmd scan \
  --out /var/log/p2s/$(date +\%F) --parallel 10
```

---

## 6. Operations and maintenance

### 6.1 Backups and rollback

Every changed file is backed up before being overwritten:

```
/etc/apache2/conf-available/php2shell-guard.conf.p2s-backup.20261021T225500Z
```

Rollback:

```bash
cp /etc/apache2/conf-available/php2shell-guard.conf.p2s-backup.20261021T225500Z \
   /etc/apache2/conf-available/php2shell-guard.conf
systemctl reload apache2
```

### 6.2 Removing the mitigation after the update

After a successful update the mitigation is no longer required — but
`memory_limit = -1` without a cgroup limit is a DoS risk. Either restore a
realistic `memory_limit` or keep `MemoryMax`. To remove the managed block:

```bash
sed -i '/^; >>> php2shell-guard >>>$/,/^; <<< php2shell-guard <<<$/{/php2shell-guard/d}' \
  /etc/php/8.3/fpm/pool.d/www.conf
systemctl reload php8.3-fpm
```

### 6.3 Monitoring

| Indicator | Source | Threshold |
|---|---|---|
| unpatched PHP version | `scan --json` | immediately |
| `CRITICAL`/`HIGH` IOC findings | `ioc --json` | immediately |
| `PHP_SESSION_UPLOAD_PROGRESS` in access log | web server log | > 0 |
| `Allowed memory size` / `Segmentation fault` | PHP-FPM log | > 0 |

---

## 7. Troubleshooting

| Message | Cause | Solution |
|---|---|---|
| `No PHP installation found on this host` | PHP only in containers or a non-standard path | set `--docroot`/`--url`; run inside the container |
| `Root privileges required` | `mitigate`/`patch --apply` without sudo | run with `sudo` |
| `No Apache configuration directory found` | Apache not under `/etc/apache2` or `/etc/httpd` | check the path; use `templates` and integrate manually |
| `No PHP-FPM pool files found` | FPM in a non-standard location | use `P2S_CONF_ROOT` or your own template |
| `Probe not retrievable` | web server not reachable at that URL | set `--url`/`--vhost`/`--probe-path` |
| `Probe response contains no executed PHP output` | server returns source (PHP not running) | check SAPI/handler — the configuration is currently not effective |
| `Apache configuration is invalid` | drop-in conflicts with existing config | run `apachectl -t`, restore the backup |
| `ssh: Permission denied (publickey)` | wrong user/key | use `--identity`, `user@host` in the host list |
| `sudo: a password is required` | `sudo -n` without NOPASSWD | configure NOPASSWD or run as root |

---

## 8. FAQ

**Is the mitigation a fix?**
No. It defuses the known paths. Only the patched version fixes the issue.

**Why `memory_limit = -1` instead of a smaller value?**
The attack needs a controllable out-of-memory condition. A finite limit provides
exactly that. `-1` moves the boundary into a cgroup.

**Why no `RLIMIT_AS`?**
Because it produces exactly the allocation failures that can re-trigger the
affected path.

**Why does `mitigate` restart the workers?**
The stale state lives in the process. A config reload changes the configuration
but does not replace the corrupted process.

**Is `ini_set()` or a `.user.ini` enough?**
No. Both apply too late. The setting must be effective before request
initialisation — in `php.ini`, the FPM pool or the server configuration.

**Is `mitigate` safe to run repeatedly?**
Yes. The managed block is replaced, not duplicated; configuration files are
backed up first.

**What about PHP 8.1 and older?**
Those branches are EOL and have no upstream fix. `mitigate` is a stopgap only.
`patch` points this out and names the migration options (upgrade to 8.2+ or
apply a source backport).

**Can the tool be used against third-party systems?**
Only with explicit authorisation. See [`SECURITY.md`](../SECURITY.md).

---

## 9. Glossary

| Term | Meaning |
|---|---|
| **SAPI** | how PHP is plugged into the web server (`mod_php`, FPM, CGI) |
| **mod_php** | PHP as an Apache module — highest risk, because shutdown runs even when startup fails |
| **stale state** | request state that outlives a request and is consumed by the next one |
| **admin-enforced** | set via `php_admin_value`, **not** overridable by the application |
| **EOL** | end of life — branch without further upstream support |
| **cgroup / `MemoryMax`** | container/systemd memory boundary — the recommended form of limiting |
| **IOC** | indicator of compromise |
| **WAF** | web application firewall |

---

## 10. Support

* Issues: <https://github.com/nesirat/php2shell-guard/issues>
* Security reports: see [`SECURITY.md`](../SECURITY.md)
