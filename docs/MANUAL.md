# Manual — php2shell-guard

> Vollständige Bedienungsanleitung. Für den Schnellstart siehe [`../README.md`](../README.md).
> English version: [`MANUAL.en.md`](MANUAL.en.md)

---

## 1. Installation

### 1.1 Single-File-Bundle (empfohlen für Flotten)

Keine Installation, keine Abhängigkeiten. Eine Datei, die per stdin auf den
Zielhost kopiert wird.

```bash
git clone git@github.com:nesirat/php2shell-guard.git
cd php2shell-guard
make bundle
ls -l dist/php2shell-guard.sh
```

Auf dem Zielhost:

```bash
curl -fsSL https://raw.githubusercontent.com/nesirat/php2shell-guard/main/dist/php2shell-guard.sh \
  | sudo bash -s -- scan --json
```

> Wer das Bundle selbst baut, kontrolliert den Code. Wer es herunterlädt, sollte
> die Prüfsumme prüfen (`shasum -a 256 dist/php2shell-guard.sh`).

### 1.2 Installation aus dem Quelltext

```bash
sudo make install PREFIX=/usr/local
# → /usr/local/bin/php2shell-guard
# → /usr/local/bin/php2shell-fleet
# → /usr/local/share/php2shell-guard/templates/
```

### 1.3 Voraussetzungen

| Werkzeug | Wo | Für |
|---|---|---|
| `bash` ≥ 3.2 | überall | alle Kommandos |
| `grep`, `sed`, `awk`, `find` | POSIX | alle Kommandos |
| `curl` | optional | `verify` |
| `ssh` | optional | `php2shell-fleet` |
| `python3` | optional | nur die Testsuite (JSON-Validierung) |

Geprüft auf Debian/Ubuntu, RHEL/Rocky/Alma, Alpine, SUSE und macOS (BSD-Werkzeuge).

---

## 2. Konzepte in 30 Sekunden

```
scan      →  Was läuft hier, ist es gepatcht, ist die Mitigation aktiv?
mitigate  →  Notfallschutz setzen (admin-gesichert) + Worker neu starten
patch     →  Auf gepatchte Version aktualisieren
verify    →  Wirkt die Konfiguration wirklich? (effektiv, über HTTP)
ioc       →  Wurde hier eventuell eingebrochen?
report    →  Ergebnisse mehrerer Hosts zusammenführen
```

**Reihenfolge bei einer akuten Lücke:** `scan` → `mitigate` → `patch` → `verify` → `ioc`.

**Exit-Codes (gelten für alle Kommandos):**

| Code | Bedeutung |
|---|---|
| `0` | Erfolg, kein kritischer Befund |
| `1` | Fehler (Konfiguration, Rechte, Netzwerk) |
| `2` | **Kritischer Befund** — ungepatchte PHP-Version ohne wirksame Mitigation |
| `64` | unbekannter Befehl |

`2` ist bewusst kein „Fehler“, sondern ein *Befund* — so lässt sich das Tool
direkt als CI-Gate verwenden.

---

## 3. Kommando-Referenz

### 3.1 `scan` — Inventarisierung

```bash
php2shell-guard scan [--json]
```

Ermittelt je Host: installierte PHP-Versionen (CLI, FPM, CGI), den tatsächlich
genutzten SAPI, die Wirksamkeit der Mitigation und den Patch-Status.

| Option | Bedeutung |
|---|---|
| `--json` | maschinenlesbare Ausgabe |

Beispielausgabe:

```
==> PHP2Shell-Scan auf rv1033
[*] OS: ubuntu 22.04 | Paketmanager: apt
[*] SAPI: mod_php=yes fpm=no nginx=no cgi=no

  SAPI           PHP          Fix ab     gepatcht   Risiko    fehlende Mitigation
  apache2handler 8.1.2-1ubuntu2.27 kein-Fix(EOL) nein       critical   memory_limit session.upload_progress.enabled
```

JSON-Felder je Installation:

| Feld | Bedeutung |
|---|---|
| `sapi` | `apache2handler`, `fpm`, `cgi-fcgi`, `cli` |
| `php_version` | installierte Version (inkl. Distro-Suffix) |
| `branch` | `8.1`, `8.3`, … |
| `fixed_min` | Version mit offiziellem Fix — **leer = EOL-Branch ohne Upstream-Fix** |
| `patched` | `true`/`false` |
| `mitigation` | `applied` / `partial` / `missing` |
| `risk` | `low` / `medium` / `critical` |
| `memory_limit_enforcement` | `admin` (wirksam) / `ini` (aushebelbar) / `none` |
| `missing` | Liste nicht wirksamer Maßnahmen |

**Interpretation `mitigation`:**

| Wert | Bedeutung |
|---|---|
| `applied` | `memory_limit=-1` **und** `session.upload_progress.enabled=0` admin-gesichert gesetzt |
| `partial` | nur ein Teil gesetzt oder nicht admin-gesichert (Anwendung kann `ini_set()` nutzen) |
| `missing` | nichts wirksam gesetzt |

**Interpretation `risk`:**

| Wert | Bedeutung |
|---|---|
| `low` | Version enthält den offiziellen Fix |
| `medium` | ungepatcht, aber Mitigation vollständig wirksam — **Update trotzdem Pflicht** |
| `critical` | ungepatcht und keine wirksame Mitigation |

### 3.2 `mitigate` — Notfallschutz

```bash
sudo php2shell-guard mitigate [--dry-run] [--yes] [--fix-overrides]
                                [--post-max 8M] [--upload-max 8M]
                                [--cgroup-limit 1024] [--json]
```

| Option | Bedeutung |
|---|---|
| `--dry-run` | nur anzeigen, nichts schreiben |
| `--yes` | Rückfragen automatisch bestätigen |
| `--fix-overrides` | `php_value`-Overrides in vHosts auf `php_admin_value` umstellen |
| `--post-max` | Wert für `post_max_size` (Standard `8M`) |
| `--upload-max` | Wert für `upload_max_filesize` (Standard `8M`) |
| `--cgroup-limit` | `MemoryMax` in MB für den FPM-Service (empfohlen) |

**Was geschrieben wird:**

| SAPI | Zieldatei |
|---|---|
| Apache `mod_php` | `/etc/apache2/conf-available/php2shell-guard.conf` (+ `a2enconf`) bzw. `/etc/httpd/conf.d/php2shell-guard.conf` |
| PHP-FPM | jeder Pool in `/etc/php/<ver>/fpm/pool.d/*.conf` (je Pool `php_admin_value[]`) |
| php-cgi | `/etc/php/<ver>/cgi/conf.d/99-php2shell-guard.ini` bzw. `/etc/php.d/99-php2shell-guard.ini` |
| nginx | `/etc/nginx/conf.d/php2shell-guard.conf` |

**Ablauf:**

1. Backup der betroffenen Dateien (`*.p2s-backup.<timestamp>`)
2. Konfiguration schreiben (markiert mit `>>> php2shell-guard >>>` / `<<< php2shell-guard <<<`)
3. Konfiguration auf Gültigkeit prüfen (`apachectl -t`, `nginx -t`)
4. **Alle Worker neu starten** (FPM-Reload, Apache graceful)

**Idempotenz:** Ein zweiter Lauf ersetzt den verwalteten Block, statt einen
zweiten anzulegen. Bestehende Pool-Einstellungen bleiben erhalten.

**Wichtig:**

* `memory_limit = -1` ist **beabsichtigt** (der Angriff braucht ein kontrollierbares
  OOM) — setze `--cgroup-limit`, sonst ist die DoS-Gefahr real.
* `RLIMIT_AS`/`RLIMIT_DATA` werden **nie** gesetzt.
* `post_max_size`/`upload_max_filesize` auf den tatsächlichen Bedarf anpassen,
  wenn die Anwendung große Uploads braucht.

**`--fix-overrides`:** VHosts, die `php_value memory_limit` setzen, hebeln die
Server-ebene aus. Das Flag stellt sie auf `php_admin_value memory_limit -1` um
(mit Backup).

### 3.3 `patch` — Update

```bash
php2shell-guard patch [--apply] [--dry-run] [--yes] [--json]
```

| Option | Bedeutung |
|---|---|
| `--apply` | Update tatsächlich durchführen (vorher Root-Rechte nötig) |
| `--dry-run` | nur simulieren |

Das Kommando listet installierte PHP-Pakete, verfügbare Updates und warnt bei
EOL-Branches mit konkreter Migrationsempfehlung. Mit `--apply` werden nur
PHP-Pakete aktualisiert (`--only-upgrade` bzw. `upgrade <paket>`) und danach
FPM/Apache neu gestartet.

### 3.4 `verify` — effektive Konfiguration prüfen

```bash
php2shell-guard verify [--url URL] [--vhost HOST] [--docroot PFAD] [--probe-path PFAD] [--json]
```

| Option | Bedeutung |
|---|---|
| `--url` | Basis-URL des Webservers (Standard `http://127.0.0.1/`) |
| `--vhost` | `Host:`-Header für die Anfrage |
| `--docroot` | Web-Root (Standard: automatisch erkannt) |
| `--probe-path` | URL-Pfad der Probe, falls der DocRoot nicht dem URL-Root entspricht |

Ablauf: temporäre Probe-Datei in den Web-Root (`__p2s_probe_<pid>.php`) →
Abruf **dieser Datei** über HTTP → Auswertung der effektiven `ini`-Werte →
Löschen der Probe.

Geprüft werden: `memory_limit`, `session.upload_progress.enabled`,
`post_max_size`, `upload_max_filesize`, `max_input_nesting_level`,
`max_input_vars`, `max_file_uploads`, `fatal_error_backtraces` (nur 8.5+).
Zusätzlich wird der Patch-Status der laufenden Version geprüft.

Ist der Webserver nicht unter `127.0.0.1` erreichbar (Container, NAT), muss
`--url` gesetzt werden.

### 3.5 `ioc` — Kompromittierungs-Indikatoren

```bash
php2shell-guard ioc [--since-days 14] [--max-files 500] [--json]
```

| Option | Bedeutung |
|---|---|
| `--since-days` | Zeitfenster für „kürzlich geändert“ (Standard 14) |
| `--max-files` | Maximalzahl gemeldeter Treffer je Kategorie |

Exit-Code `1`, wenn mindestens ein Treffer gemeldet wird. Details und
Handlungsanleitung: [`DETECTION.md`](DETECTION.md).

### 3.6 `report` — Auswertung

```bash
php2shell-guard report [--out DATEI.md] [--csv DATEI.csv] <scan.json> [scan.json …]
```

Erzeugt eine Markdown-Tabelle über alle Hosts mit Risiko-Zählung und
Handlungsbedarf-Hinweis. Leerer `fixed_min` wird als „kein-Fix(EOL)“ ausgewiesen.

### 3.7 `templates` — Konfiguration ansehen

```bash
php2shell-guard templates [apache|fpm|ini|nginx|all]
```

Gibt die verwaltete Konfiguration so aus, wie sie geschrieben würde — nützlich
für die Integration in eigenes Configuration-Management (Ansible, Puppet, Git).

---

## 4. Flottenbetrieb

Details: [`FLEET.md`](FLEET.md).

```bash
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd scan --parallel 10
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd mitigate --sudo --parallel 5
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd scan --report fleet-report.md
```

| Option | Bedeutung |
|---|---|
| `--hosts <datei>` | Hostliste (Pflicht), `user@host` pro Zeile |
| `--cmd <befehl>` | `scan` (Standard), `mitigate`, `patch`, `verify`, `ioc` |
| `--parallel <n>` | parallele Verbindungen (Standard 8) |
| `--sudo` | Remote-Befehl mit `sudo -n` (NOPASSWD nötig) |
| `--identity <key>` | SSH-Identity |
| `--ssh-opts "<opt>"` | zusätzliche SSH-Optionen |
| `--extra "<args>"` | Zusatzargumente für den Remote-Befehl |
| `--out <dir>` | Ergebnisverzeichnis |
| `--report <datei>` | Markdown-Report |
| `--local` | lokal statt per SSH ausführen (Tests) |

**Rollout-Plan:** siehe [`FLEET.md`, Abschnitt 7](FLEET.md#7-rollout-empfehlung).

---

## 5. CI-Integration

### 5.1 Gate in der Pipeline

```yaml
- name: PHP2Shell-Gate
  run: |
    curl -fsSL https://raw.githubusercontent.com/nesirat/php2shell-guard/main/dist/php2shell-guard.sh \
      | sudo bash -s -- scan --json
```

Exit-Code `2` bricht den Build. Wer das Tool nicht mit sudo ausführen will,
nimmt `--dry-run` bzw. scannt als unprivilegierter Benutzer — `scan` braucht
keine Root-Rechte.

### 5.2 Container-Build

```dockerfile
RUN curl -fsSL .../php2shell-guard.sh | bash -s -- scan --json
```

Bricht den Image-Build, wenn die PHP-Version ungepatcht ist.

### 5.3 Tägliche Inventarisierung

```bash
0 6 * * * /usr/local/bin/php2shell-fleet --hosts /etc/p2s/hosts.txt --cmd scan \
  --out /var/log/p2s/$(date +\%F) --parallel 10
```

### 5.4 Tickets automatisch anlegen

Der JSON-Output ist stabil und eignet sich als Input für Ticket-Systeme:

```bash
php2shell-guard scan --json \
  | jq -r '.installs[] | select(.risk == "critical") | "\(.sapi) \(.php_version)"'
```

---

## 6. Betrieb und Wartung

### 6.1 Backups und Rollback

Jede geänderte Datei wird vor dem Überschreiben gesichert:

```
/etc/apache2/conf-available/php2shell-guard.conf.p2s-backup.20261021T225500Z
```

Rollback:

```bash
cp /etc/apache2/conf-available/php2shell-guard.conf.p2s-backup.20261021T225500Z \
   /etc/apache2/conf-available/php2shell-guard.conf
systemctl reload apache2
```

### 6.2 Nach dem Update: Mitigation zurückbauen?

Nach einem erfolgreichen Update sind `memory_limit = -1` und
`session.upload_progress.enabled = 0` **nicht mehr nötig** — aber auch nicht
mehr schädlich. `memory_limit = -1` ohne cgroup-Grenze ist allerdings eine
DoS-Gefahr. Deshalb:

* `memory_limit` auf einen realistischen Wert zurücksetzen (z. B. `256M`) **oder**
* `MemoryMax` beibehalten und `memory_limit` zurücksetzen.

Zurückbauen lässt sich durch Entfernen des verwalteten Blocks:

```bash
sed -i '/^; >>> php2shell-guard >>>$/,/^; <<< php2shell-guard <<<$/{/php2shell-guard/d}' \
  /etc/php/8.3/fpm/pool.d/www.conf
systemctl reload php8.3-fpm
```

### 6.3 Monitoring

| Indikator | Quelle | Schwelle |
|---|---|---|
| PHP-Version ungepatcht | `scan --json` | sofort |
| `KRITISCH`/`HOCH`-IOC-Treffer | `ioc --json` | sofort |
| `PHP_SESSION_UPLOAD_PROGRESS` im Access-Log | Webserver-Log | > 0 |
| `Allowed memory size` / `Segmentation fault` | PHP-FPM-Log | > 0 |

---

## 7. Troubleshooting

| Meldung | Ursache | Lösung |
|---|---|---|
| `Keine PHP-Installation auf diesem Host gefunden` | PHP nur in Containern oder unter anderem Pfad | `--docroot`/`--url` prüfen; ggf. in Containern ausführen |
| `Root-Rechte erforderlich` | `mitigate`/`patch --apply` ohne sudo | mit `sudo` ausführen |
| `Kein Apache-Konfigurationsverzeichnis gefunden` | Apache nicht unter `/etc/apache2` oder `/etc/httpd` | Pfad prüfen; Alternative: `templates` + eigene Einbindung |
| `Keine PHP-FPM-Pool-Dateien gefunden` | FPM unter abweichendem Pfad | `P2S_CONF_ROOT` oder eigenes Template nutzen |
| `Probe nicht abrufbar` | Webserver nicht unter der URL erreichbar | `--url`/`--vhost`/`--probe-path` setzen |
| `Probe-Antwort enthält keinen ausgeführten PHP-Output` | Server liefert Quelltext aus (PHP läuft nicht) | SAPI/Handler prüfen — Konfiguration wirkt derzeit nicht |
| `Apache-Konfiguration ungültig` | Drop-in kollidiert mit bestehender Config | `apachectl -t` ausführen, Backup zurückspielen |
| `Inventarisierung fehlgeschlagen` | unerwarteter Fehler in der Konfigurationsauswertung | `--json` prüfen, Logs lesen |
| `ssh: Permission denied (publickey)` | falscher User/Key | `--identity`, `user@host` in der Hostliste |
| `sudo: a password is required` | `sudo -n` ohne NOPASSWD | NOPASSWD-Regel einrichten oder als root laufen |
| `Repository not found` (beim Push) | GitHub-Repo existiert nicht | Repo anlegen (leer, ohne README) und erneut pushen |

Diagnose-Werkzeuge:

```bash
apachectl -M | grep -i php          # mod_php geladen?
apachectl -t                        # Konfiguration gültig?
php -i | grep -E 'memory_limit|upload_progress'
ps aux | grep -c '[p]hp-fpm'        # Worker-Anzahl
```

---

## 8. FAQ

**Ist die Mitigation ein Fix?**
Nein. Sie entschärft die bekannten Pfade. Nur die gepatchte Version behebt die Lücke.

**Warum `memory_limit = -1` statt eines kleineren Werts?**
Der Angriff braucht einen kontrollierbaren Speichererschöpfungs-Zustand. Ein
endliches Limit liefert genau diesen. `-1` verlagert die Grenze in eine cgroup.

**Warum kein `RLIMIT_AS`?**
Weil es genau die Allocation-Fehler erzeugt, die den betroffenen Pfad erneut
auslösen können.

**Warum startet `mitigate` die Worker neu?**
Weil der stale state im Prozess lebt. Ein Config-Reload ändert die
Konfiguration, ersetzt aber nicht den korrupten Prozess.

**Reicht `session.upload_progress.enabled=0` in der `.htaccess`?**
Nein. `.user.ini` und `ini_set()` greifen zu spät bzw. werden zu spät angewendet.
Der Wert muss vor der Request-Initialisierung wirksam sein — also in `php.ini`,
im FPM-Pool oder in der Server-Konfiguration.

**Kann ich `mitigate` gefahrlos mehrfach laufen lassen?**
Ja. Der verwaltete Block wird ersetzt statt dupliziert; Konfigurationsdateien
werden vorher gesichert.

**Was passiert bei PHP 8.1 und älter?**
Diese Branches sind EOL und haben keinen Upstream-Fix. `mitigate` wirkt dort
nur als Notfallschutz. `patch` weist darauf hin und nennt die
Migrationsoptionen (Upgrade auf 8.2+ oder Source-Backport).

**Ist `verify` sicher in der Produktion?**
Die Probe enthält keine Geheimnisse, hat einen zufälligen Dateinamen und wird
unmittelbar nach dem Abruf gelöscht. Sie erzeugt eine zusätzliche, minimale
HTTP-Anfrage.

**Kann ich mit dem Tool fremde Systeme prüfen?**
Nur mit ausdrücklicher Autorisierung. Siehe [`SECURITY.md`](../SECURITY.md).

---

## 9. Glossar

| Begriff | Bedeutung |
|---|---|
| **SAPI** | Server Application Programming Interface — wie PHP in den Webserver eingebunden ist (`mod_php`, FPM, CGI) |
| **mod_php** | PHP als Apache-Modul — höchstes Risiko, weil der Shutdown auch bei fehlgeschlagenem Startup läuft |
| **stale state** | Request-Zustand, der das Ende eines Requests überlebt und vom nächsten Request konsumiert wird |
| **admin-gesichert** | über `php_admin_value` gesetzt und durch die Anwendung **nicht** überschreibbar |
| **EOL** | End of Life — Branch ohne weitere Upstream-Support |
| **cgroup / `MemoryMax`** | Container- bzw. systemd-Speichergrenze; die empfohlene Form der Begrenzung |
| **IOC** | Indicator of Compromise — Hinweis auf eine Kompromittierung |
| **WAF** | Web Application Firewall |

---

## 10. Support

* Issues: <https://github.com/nesirat/php2shell-guard/issues>
* Sicherheitsmeldungen: siehe [`SECURITY.md`](../SECURITY.md)
* Autor: NTPaS / nesirat
