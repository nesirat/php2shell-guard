# php2shell-guard

[![Lizenz: MIT](https://img.shields.io/badge/Lizenz-MIT-blue.svg)](LICENSE)
[![PHP2Shell](https://img.shields.io/badge/CVE-2026--109618%20%7C%20CVE-2026--109619-critical-red.svg)](https://www.php.net/archive/2026.php#2026-10-21-5)

Sammel-Werkzeug für die **PHP2Shell**-Lücke (CVE-2026-109618 / CVE-2026-109619):
Inventarisierung, Notfall-Mitigation, Update-Steuerung und Kompromittierungs-Prüfung
für **ganze Host-Flotten** — in einem Durchlauf, per SSH.

> **Kernaussage:** Das Update auf eine gepatchte PHP-Version ist die **einzige**
> vollständige Behebung. Alles, was dieses Werkzeug tut, ist ein **Notfallschutz**
> für die Stunden bis zum Update — und ein Werkzeug, das sicherstellt, dass die
> Notfallmaßnahme überhaupt auf allen Hosts ankommt.

---

## Das Problem in 60 Sekunden

Am 21.10.2026 hat das PHP-Projekt zwei kritische RCE-Lücken veröffentlicht:

| CVE | CVSS | Mechanismus | Betroffen |
|---|---|---|---|
| CVE-2026-109618 | 9.2 | OOM während Request-Startup → `longjmp()` auf teilweise initialisiertem Speicher → RCE | PHP 5.4 – 8.5.11 |
| CVE-2026-109619 | 9.8 | Request-State überlebt den Worker (stale state) → Folge-Request konsumiert freigegebenen Speicher → RCE | PHP 5.4 – 8.5.11 |

Gepatchte Versionen: **8.5.12**, **8.4.27**, **8.3.36**, **8.2.35**.
Branches 8.1 und älter sind EOL — dort gibt es **keinen** Upstream-Fix
(nur minimale Source-Backports der PHP-Team-Repos `PHP-<branch>-CVE-2026-109618-109619`).

**Höchstes Risiko: `mod_php`** (Apache-Modul). Dort läuft der Request-Shutdown
auch dann, wenn der Startup scheitert — der Angriff funktioniert also
**anwendungsunabhängig, bevor ein einziges Zeile Anwendungscode läuft**.
PHP-FPM ist ebenfalls betroffen (State wird nachgelagert publiziert), aber
nicht im selben Ausmaß anwendungsunabhängig.

Details: [`docs/MITIGATION.md`](docs/MITIGATION.md) · [`docs/ADVISORY-2026-10-21.md`](docs/ADVISORY-2026-10-21.md)
Vollständige Bedienungsanleitung: **[`docs/MANUAL.md`](docs/MANUAL.md)**

---

## Schnellstart

### 1. Bestand aufnehmen (read-only, ohne Rechte)

```bash
./bin/php2shell-guard scan
./bin/php2shell-guard scan --json > scan.json
```

Ausgabe:

```
  SAPI           PHP          Fix ab     gepatcht   Risiko    fehlende Mitigation
  apache2handler 8.1.2-1ubuntu2.27 kein-Fix(EOL) nein       critical   memory_limit session.upload_progress.enabled
```

Exit-Codes: `0` = alles gepatcht, `2` = mindestens eine kritische Installation
(ideal als **CI-Gate**).

### 2. Notfall-Mitigation verteilen

```bash
./bin/php2shell-guard mitigate --dry-run     # erst ansehen
sudo ./bin/php2shell-guard mitigate           # dann anwenden
```

Legt je nach SAPI eine **verwaltete** Konfiguration an:

| SAPI | Datei | Wirkung |
|---|---|---|
| Apache `mod_php` | `/etc/apache2/conf-available/php2shell-guard.conf` (Debian) bzw. `/etc/httpd/conf.d/php2shell-guard.conf` (RHEL) | `php_admin_value` für `memory_limit`, `session.upload_progress.enabled`, `fatal_error_backtraces` (8.5), Eingabe-Limits + `LimitRequestBody` |
| PHP-FPM | je Pool-Datei (`/etc/php/<ver>/fpm/pool.d/*.conf`) | `php_admin_value[...]` je Pool (FPM kennt keine globale Pool-Config) |
| php-cgi | `/etc/php/<ver>/cgi/conf.d/99-php2shell-guard.ini` | INI-Werte (schwächer, da `PHP_INI_ALL`) |
| nginx | `/etc/nginx/conf.d/php2shell-guard.conf` | `client_max_body_size`, Timeouts |

Anschließend werden **alle Worker neu gestartet** — zwingend, weil der
stale state im Worker-Prozess lebt und ein Config-Reload ihn nicht auflöst.

### 3. Update fahren

```bash
./bin/php2shell-guard patch            # nur prüfen, was verfügbar ist
sudo ./bin/php2shell-guard patch --apply
```

### 4. Prüfen

```bash
./bin/php2shell-guard verify --url https://example.org/ --vhost example.org
./bin/php2shell-guard ioc --since-days 30
```

`verify` legt temporär eine Probe-Datei im Web-Root ab, ruft **diese Datei**
über HTTP ab, liest die **effektive** Konfiguration aus (nicht die Datei auf
der Platte — das ist der Unterschied, der zählt) und löscht die Probe wieder.
Liegt der DocRoot nicht auf dem URL-Root, `--probe-path <URL-Pfad>` angeben.

---

## Der Batch: ganze Flotte in einem Durchlauf

Genau die Frage „kann ich das für Apache stapelweise machen?“ — ja:

```bash
make bundle                                   # Single-File-Bundle bauen
./bin/php2shell-fleet --hosts hosts.txt --cmd scan --parallel 10
./bin/php2shell-fleet --hosts hosts.txt --cmd mitigate --sudo --parallel 10
./bin/php2shell-fleet --hosts hosts.txt --cmd scan --report fleet-report.md
```

`hosts.txt` — eine Zeile pro Host, `#`-Kommentare erlaubt:

```
# web01.example.org
root@10.0.0.11
deploy@10.0.0.12
```

Das Bundle (`dist/php2shell-guard.sh`) ist **eine einzelne Datei** ohne
Abhängigkeiten und wird per SSH über stdin auf den Zielhost kopiert — nichts
muss auf dem Zielhost installiert sein.

* `--sudo` nutzt `sudo -n` (NOPASSWD erforderlich) für `mitigate`/`patch`.
* `--dry-run` wird an den Remote durchgereicht.
* Exit-Code `2` eines Hosts (= kritischer Befund) wird als `KRITISCH` ausgewiesen,
  nicht als Fehler.
* Ergebnis: JSON pro Host + Markdown-/CSV-Gesamtreport.

Details: [`docs/FLEET.md`](docs/FLEET.md)

---

## Allgemeine Lösung statt Einzelfall-Hack

Die nachhaltige Antwort besteht aus vier Ebenen — dieses Werkzeug deckt alle vier ab:

| Ebene | Maßnahme | Werkzeug |
|---|---|---|
| **1. Inventar** | wissen, wo überhaupt PHP läuft (auch EOL-Branches, auch CLI) | `scan` |
| **2. Notfallschutz** | Maßnahmen admin-gesichert setzen + Worker neu starten | `mitigate` |
| **3. eigentliche Fix** | Update auf gepatchte Version, auch für EOL-Branches migrieren | `patch` |
| **4. Nachweis** | Kompromittierung prüfen, Maßnahme verifizieren, Zustand dokumentieren | `ioc`, `verify`, `report` |

Zusätzlich als **Dauer-Gate** (CI):

```yaml
- name: PHP2Shell-Gate
  run: |
    curl -fsSL https://github.com/nesirat/php2shell-guard/releases/download/v0.1.0/php2shell-guard.sh \
      | sudo bash -s -- scan --json
```

Exit-Code `2` bricht den Build — ungepatchte PHP-Versionen können so nicht
versehentlich in Produktion landen.

---

## Was die Mitigation leistet — und was nicht

**Leistet (temporär):**

* `memory_limit = -1` **admin-gesichert** (via `php_admin_value`) — nimmt das
  kontrollierbare OOM aus dem Spiel.
* `session.upload_progress.enabled = 0` **admin-gesichert** — schließt den
  bestätigten Producer/Consumer-Pfad für stale state.
* `fatal_error_backtraces = 0` (nur PHP 8.5) — entfernt den bestätigten
  Producer im 8.5-Fall.
* `post_max_size` / `upload_max_filesize` / `max_input_nesting_level` /
  `max_input_vars` / `max_file_uploads` — begrenzen den Angriffsraum.
* `LimitRequestBody` / `LimitRequestFields` / `LimitRequestFieldSize` (Apache)
  bzw. `client_max_body_size` (nginx) — greifen **vor** dem PHP-Parser.
* `--cgroup-limit` setzt eine **Verfügbarkeitsgrenze** (`MemoryMax`), damit
  `memory_limit = -1` nicht in eine DoS-Lücke kippt.

**Leistet NICHT:**

* Es **behebt** die Lücke nicht. Ein Allokationsfehler unterhalb von
  `memory_limit = -1` kann den betroffenen Pfad weiterhin erreichen.
* Multipart-Teilanzahl und Headeranzahl pro Teil lassen sich in **nginx**
  nativ nicht begrenzen — dafür braucht es WAF/ModSecurity/NAXSI.
* `RLIMIT_AS` / `RLIMIT_DATA` dürfen **nicht** gesetzt werden: sie erzeugen
  genau die Allocation-Fehler, die den Path erneut auslösen. Das Werkzeug setzt
  bewusst `MemoryMax` (cgroup) stattdessen.
* `ini_set()` und `.user.ini` sind **kein** Ersatz — sie greifen zu spät bzw.
  werden zu spät angewendet.

---

## Kommandos

| Kommando | Zweck | Rechte |
|---|---|---|
| `scan` | PHP-Versionen, SAPIs, Mitigation-Status | keine |
| `mitigate` | Notfall-Mitigation + Worker-Neustart | root |
| `patch` | Paket-Update (mit `--apply`) | root für `--apply` |
| `verify` | effektive Konfiguration über HTTP prüfen | keine (schreibt Probe in Web-Root) |
| `ioc` | Kompromittierungs-Indikatoren | Lesezugriff auf Web-Root/Logs |
| `report` | JSON-Ergebnisse → Markdown/CSV | keine |
| `templates` | anzuwendende Config anzeigen | keine |

Globale Optionen: `--json`, `--dry-run`, `--yes`, `--version`, `--help`.

Vollständige Kommando-Referenz, Troubleshooting, FAQ und Betriebs-/Rollout-Handbuch:
**[`docs/MANUAL.md`](docs/MANUAL.md)** (EN: [`docs/MANUAL.en.md`](docs/MANUAL.en.md)).

---

## Voraussetzungen

* `bash` ≥ 3.2, `grep`/`sed`/`awk`/`find` (POSIX) — keine Python-/jq-Pflicht
* `curl` nur für `verify`
* `ssh` nur für `php2shell-fleet`
* getestet auf Debian/Ubuntu, RHEL/Rocky/Alma, Alpine, macOS (BSD-Werkzeuge!)

---

## Contributing

Beiträge willkommen — besonders: **neue Betriebssysteme**, **neue SAPI**,
**weitere IOC-Muster**, **Ansible-/Salt-Integrationen**.
Siehe [`CONTRIBUTING.md`](CONTRIBUTING.md) und [`SECURITY.md`](SECURITY.md).

Dieses Werkzeug ist bewusst **frei zugänglich** gehalten: Die Zeit zwischen
Veröffentlichung einer Lücke und dem Patchen einzelner Systeme ist die Zeit,
in der Angreifer zuverlässig Systeme übernehmen. Werkzeuge, die diese Zeit
verkürzen, gehören in die Hände aller Betroffenen — nicht in eine Nische.

## Quellen

* PHP Security Advisory: <https://www.php.net/archive/2026.php#2026-10-21-5>
* GHSA-w8hw-w9fx-j79w (CVE-2026-109618): <https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w>
* GHSA-6wmf-4rv5-p3rp (CVE-2026-109619): <https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp>
* NCSC (UK): <https://www.ncsc.gov.uk/news/critical-security-issue-affecting-php>
* EOL-Backports: <https://github.com/php/php-src/tree/PHP-8.1-CVE-2026-109618-109619>

## Lizenz

MIT — siehe [`LICENSE`](LICENSE). English version: [`README.en.md`](README.en.md).
